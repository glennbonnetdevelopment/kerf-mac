using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO.Ports;
using System.Text;
using System.Threading;

namespace KerfSender
{
    /// <summary>
    /// A GRBL controller on a serial port. Events are raised on the thread that created it
    /// (the UI thread), so handlers can touch controls directly.
    /// </summary>
    public sealed class GrblConnection : IDisposable
    {
        public event Action<string, bool> Log;          // text, isError
        public event Action<string> StatusChanged;      // e.g. "Idle  X 10.000  Y 5.000"
        public event Action<double> Progress;           // 0..1
        public event Action<string> JobFinished;        // summary
        public event Action Disconnected;

        readonly SynchronizationContext ui;
        SerialPort port;
        GrblStreamer streamer;
        readonly StringBuilder rx = new StringBuilder();
        System.Windows.Forms.Timer statusTimer;
        int jobFirstAck, jobLineCount;
        DateTime jobStarted;

        public bool IsConnected { get { return port != null; } }
        public bool IsRunning { get; private set; }
        public bool IsPaused { get; private set; }
        public string State { get; private set; }

        public GrblConnection()
        {
            ui = SynchronizationContext.Current ?? new SynchronizationContext();
            State = "Disconnected";
        }

        public void Open(string portName, int baud, int rxBufferSize)
        {
            if (port != null) return;
            var p = new SerialPort(portName, baud, Parity.None, 8, StopBits.One);
            p.Handshake = Handshake.None;
            p.DtrEnable = true;
            p.RtsEnable = true;
            p.Encoding = Encoding.ASCII;
            p.NewLine = "\n";
            p.WriteTimeout = 2000;
            p.DataReceived += OnData;
            p.ErrorReceived += (s, e) => Post(() => Emit("Serial error: " + e.EventType, true));
            p.Open();
            port = p;
            streamer = new GrblStreamer(rxBufferSize);
            rx.Length = 0;
            State = "Connecting";
            Emit("Opened " + portName + " at " + baud + " baud", false);
            statusTimer = new System.Windows.Forms.Timer { Interval = 250 };
            statusTimer.Tick += (s, e) => Realtime(0x3F); // ?
            statusTimer.Start();
            // GRBL boards often reset when the port opens; ask for build info once it is up.
            var t = new System.Windows.Forms.Timer { Interval = 1500 };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); if (IsConnected) Send("$I"); };
            t.Start();
        }

        public void Close() { HandleDisconnect("Disconnected."); }

        public void Dispose() { HandleDisconnect(null); }

        void HandleDisconnect(string reason)
        {
            if (port == null) return;
            if (statusTimer != null) { statusTimer.Stop(); statusTimer.Dispose(); statusTimer = null; }
            var p = port;
            port = null;
            try { p.DataReceived -= OnData; p.Close(); } catch { }
            p.Dispose();
            IsRunning = false;
            IsPaused = false;
            if (streamer != null) streamer.Reset();
            State = "Disconnected";
            if (reason != null)
            {
                Emit(reason, false);
                if (StatusChanged != null) StatusChanged(State);
                if (Disconnected != null) Disconnected();
            }
        }

        void Post(Action a) { ui.Post(_ => a(), null); }

        void Emit(string text, bool isError) { if (Log != null) Log(text, isError); }

        // Runs on a thread-pool thread.
        void OnData(object sender, SerialDataReceivedEventArgs e)
        {
            var p = sender as SerialPort;
            string text;
            try { text = p.ReadExisting(); }
            catch (Exception) { return; }
            Post(() => Receive(text));
        }

        void Receive(string text)
        {
            if (port == null) return;
            rx.Append(text);
            while (true)
            {
                string all = rx.ToString();
                int nl = all.IndexOf('\n');
                if (nl < 0) break;
                string line = all.Substring(0, nl).Trim();
                rx.Remove(0, nl + 1);
                if (line.Length > 0) Handle(line);
            }
        }

        void Handle(string line)
        {
            if (line == "ok")
            {
                streamer.Acknowledge(false);
                if (!IsRunning) Emit("ok", false);
                Pump();
            }
            else if (line.StartsWith("error:"))
            {
                streamer.Acknowledge(true);
                Emit(line + " " + ErrorText(ParseCode(line)), true);
                Pump();
            }
            else if (line.StartsWith("ALARM:"))
            {
                Emit(line + " " + AlarmText(ParseCode(line)), true);
                if (IsRunning)
                {
                    IsRunning = false;
                    IsPaused = false;
                    streamer.Reset();
                    Emit("Job stopped by alarm.", true);
                    if (JobFinished != null) JobFinished("Stopped by alarm.");
                }
            }
            else if (line.StartsWith("<") && line.EndsWith(">"))
            {
                ParseStatus(line.Substring(1, line.Length - 2));
            }
            else if (line.StartsWith("Grbl ") || line.StartsWith("GrblHAL "))
            {
                Emit(line, false);
                streamer.Reset();
                if (IsRunning)
                {
                    IsRunning = false;
                    IsPaused = false;
                    if (JobFinished != null) JobFinished("The controller reset.");
                }
            }
            else
            {
                Emit(line, false);
            }

            if (IsRunning)
            {
                int done = streamer.Acknowledged - jobFirstAck;
                if (Progress != null) Progress(jobLineCount > 0 ? Math.Min(1.0, (double)done / jobLineCount) : 1.0);
                if (streamer.IsIdle)
                {
                    IsRunning = false;
                    IsPaused = false;
                    var secs = (int)(DateTime.Now - jobStarted).TotalSeconds;
                    string msg = "Job finished in " + Job.FormatDuration(secs) + " with " + streamer.Errors + " error(s).";
                    Emit(msg, streamer.Errors > 0);
                    if (JobFinished != null) JobFinished(msg);
                }
            }
        }

        double[] workOffset = { 0, 0, 0 };

        void ParseStatus(string body)
        {
            string[] fields = body.Split('|');
            string state = fields[0];
            double[] mpos = null, wpos = null;
            foreach (string f in fields)
            {
                int colon = f.IndexOf(':');
                if (colon < 0) continue;
                string key = f.Substring(0, colon);
                double[] v = Numbers(f.Substring(colon + 1));
                if (key == "MPos") mpos = v;
                else if (key == "WPos") wpos = v;
                else if (key == "WCO" && v.Length >= 2) workOffset = v;
            }
            if (wpos == null && mpos != null)
            {
                wpos = new double[mpos.Length];
                for (int i = 0; i < mpos.Length; i++) wpos[i] = mpos[i] - (i < workOffset.Length ? workOffset[i] : 0);
            }
            State = state;
            var sb = new StringBuilder(state);
            if (wpos != null && wpos.Length >= 2)
            {
                sb.Append("    X ").Append(wpos[0].ToString("0.00", CultureInfo.InvariantCulture));
                sb.Append("   Y ").Append(wpos[1].ToString("0.00", CultureInfo.InvariantCulture));
                if (wpos.Length >= 3) sb.Append("   Z ").Append(wpos[2].ToString("0.00", CultureInfo.InvariantCulture));
            }
            if (StatusChanged != null) StatusChanged(sb.ToString());
        }

        static double[] Numbers(string csv)
        {
            string[] parts = csv.Split(',');
            var result = new double[parts.Length];
            for (int i = 0; i < parts.Length; i++)
                double.TryParse(parts[i], NumberStyles.Float, CultureInfo.InvariantCulture, out result[i]);
            return result;
        }

        static int ParseCode(string line)
        {
            int colon = line.IndexOf(':');
            int code;
            int.TryParse(line.Substring(colon + 1).Trim(), out code);
            return code;
        }

        void Pump()
        {
            if (port == null) return;
            List<string> lines = streamer.TakeSendable();
            if (lines.Count == 0) return;
            if (!IsRunning) foreach (string l in lines) Emit("> " + l, false);
            try
            {
                port.Write(string.Join("\n", lines.ToArray()) + "\n");
            }
            catch (Exception ex)
            {
                Emit("Write failed: " + ex.Message, true);
                HandleDisconnect("The machine was disconnected.");
            }
        }

        public void Send(string line)
        {
            if (port == null) return;
            streamer.Enqueue(new[] { line });
            Pump();
        }

        public void Realtime(byte command)
        {
            if (port == null) return;
            try { port.Write(new[] { command }, 0, 1); }
            catch (Exception ex)
            {
                Emit("Write failed: " + ex.Message, true);
                HandleDisconnect("The machine was disconnected.");
            }
        }

        public void Run(List<string> lines)
        {
            if (port == null || IsRunning) return;
            int before = streamer.Total;
            streamer.Enqueue(lines);
            jobLineCount = streamer.Total - before;
            // Lines already queued before the job are acknowledged first.
            jobFirstAck = streamer.Acknowledged + (streamer.Pending - jobLineCount) + streamer.InFlightCount;
            jobStarted = DateTime.Now;
            IsRunning = true;
            IsPaused = false;
            Emit("Job started: " + jobLineCount + " lines", false);
            if (Progress != null) Progress(0);
            Pump();
        }

        public void Pause() { Realtime(0x21); IsPaused = true; }   // !

        public void Resume() { Realtime(0x7E); IsPaused = false; } // ~

        /// <summary>Stops at once: feed hold, then a soft reset (which also turns the laser or spindle off).</summary>
        public void Stop()
        {
            Realtime(0x21);
            var t = new System.Windows.Forms.Timer { Interval = 250 };
            t.Tick += (s, e) => { t.Stop(); t.Dispose(); Realtime(0x18); };
            t.Start();
            streamer.Reset();
            bool wasRunning = IsRunning;
            IsRunning = false;
            IsPaused = false;
            if (wasRunning)
            {
                Emit("Job stopped. Re-home or re-check the origin before the next job.", false);
                if (JobFinished != null) JobFinished("Stopped.");
            }
        }

        public static string ErrorText(int code)
        {
            switch (code)
            {
                case 1: return "G-code word missing a letter";
                case 2: return "Numeric value format is not valid";
                case 3: return "'$' command not recognised";
                case 8: return "Command needs the machine to be idle";
                case 9: return "G-code locked out during alarm or jog; unlock first";
                case 15: return "Jog target exceeds machine travel";
                case 20: return "Unsupported G-code command";
                case 22: return "Feed rate has not been set";
                default: return "";
            }
        }

        public static string AlarmText(int code)
        {
            switch (code)
            {
                case 1: return "Hard limit triggered; re-home the machine";
                case 2: return "Motion target exceeds machine travel";
                case 3: return "Reset while in motion; re-home recommended";
                case 6: case 7: case 8: case 9: return "Homing failed";
                default: return "";
            }
        }
    }
}
