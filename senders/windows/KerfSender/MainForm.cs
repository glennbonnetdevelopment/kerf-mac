using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.IO.Ports;
using System.Linq;
using System.Text;
using System.Windows.Forms;

namespace KerfSender
{
    public sealed class MainForm : Form
    {
        // Job
        readonly Label jobTitle = new Label { AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 12f, FontStyle.Bold), Text = "No job open" };
        readonly Label jobSummary = new Label { AutoSize = true, ForeColor = SystemColors.GrayText, Text = "Open a .kerfjob exported from KerfKutter, or drop one on this window." };

        // Machine
        readonly ComboBox kindBox = Dropdown("GRBL laser", "GRBL CNC router", "Vinyl cutter (HPGL)", "Vinyl cutter (GP-GL)");
        readonly ComboBox outputBox = Dropdown("Serial (COM) port", "Windows printer");
        readonly ComboBox portBox = Dropdown();
        readonly ComboBox printerBox = Dropdown();
        readonly ComboBox baudBox = new ComboBox { Width = 110 };
        readonly ComboBox flowBox = Dropdown("None", "RTS/CTS (hardware)", "XON/XOFF (software)");
        readonly Button refreshButton = new Button { Text = "Refresh", AutoSize = true };
        readonly Label portLabel = new Label { Text = "Port:", AutoSize = true, Anchor = AnchorStyles.Left };
        readonly Label printerLabel = new Label { Text = "Printer:", AutoSize = true, Anchor = AnchorStyles.Left };
        readonly Label outputLabel = new Label { Text = "Send to:", AutoSize = true, Anchor = AnchorStyles.Left };
        readonly Label flowLabel = new Label { Text = "Flow control:", AutoSize = true, Anchor = AnchorStyles.Left };
        readonly Label baudLabel = new Label { Text = "Baud rate:", AutoSize = true, Anchor = AnchorStyles.Left };

        // GRBL controls
        readonly GroupBox grblGroup = new GroupBox { Text = "Machine control", Dock = DockStyle.Fill, AutoSize = true };
        readonly Button connectButton = new Button { Text = "Connect", AutoSize = true };
        readonly Button homeButton = new Button { Text = "Home", AutoSize = true };
        readonly Button unlockButton = new Button { Text = "Unlock", AutoSize = true };
        readonly Button originButton = new Button { Text = "Set origin here", AutoSize = true };
        readonly Button goOriginButton = new Button { Text = "Go to origin", AutoSize = true };
        readonly ComboBox stepBox = Dropdown("0.1 mm", "1 mm", "10 mm", "50 mm");
        readonly Button[] jogButtons;
        readonly Label statusLabel = new Label { AutoSize = true, Text = "Disconnected", Font = new Font(FontFamily.GenericMonospace, 9f) };

        // Run
        readonly Button openButton = new Button { Text = "Open Job…", AutoSize = true };
        readonly Button cameraButton = new Button { Text = "Camera…", AutoSize = true };
        readonly Button startButton = new Button { Text = "Start", AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont, FontStyle.Bold) };
        readonly Button pauseButton = new Button { Text = "Pause", AutoSize = true };
        readonly Button stopButton = new Button { Text = "Stop", AutoSize = true, ForeColor = Color.DarkRed };
        readonly ProgressBar progress = new ProgressBar { Dock = DockStyle.Fill, Maximum = 1000 };
        readonly TextBox log = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font(FontFamily.GenericMonospace, 8.5f), BackColor = SystemColors.Window };

        readonly GrblConnection grbl = new GrblConnection();
        readonly CutterSender cutter = new CutterSender();
        readonly Settings settings = Settings.Load();
        Job job;
        CameraForm cameraForm;

        public MainForm(string initialFile)
        {
            Text = "KerfSender";
            Font = SystemFonts.MessageBoxFont;
            AutoScaleMode = AutoScaleMode.Font;
            ClientSize = new Size(720, 640);
            MinimumSize = new Size(620, 520);
            StartPosition = FormStartPosition.CenterScreen;
            AllowDrop = true;

            baudBox.Items.AddRange(new object[] { "9600", "19200", "38400", "57600", "115200", "250000" });
            stepBox.SelectedIndex = 2;
            kindBox.SelectedIndex = 0;
            outputBox.SelectedIndex = 0;
            flowBox.SelectedIndex = 0;
            baudBox.Text = "115200";

            jogButtons = new[]
            {
                JogButton("Y+", 0, 1, 0), JogButton("X−", -1, 0, 0), JogButton("X+", 1, 0, 0),
                JogButton("Y−", 0, -1, 0), JogButton("Z+", 0, 0, 1), JogButton("Z−", 0, 0, -1),
            };

            BuildLayout();
            WireEvents();
            RefreshPorts();
            UpdateMachineFields();
            UpdateButtons();

            if (!string.IsNullOrEmpty(initialFile)) Shown += (s, e) => OpenJob(initialFile);
        }

        static ComboBox Dropdown(params string[] items)
        {
            var c = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 220 };
            c.Items.AddRange(items);
            return c;
        }

        Button JogButton(string text, int dx, int dy, int dz)
        {
            var b = new Button { Text = text, Width = 44, Height = 30 };
            b.Click += (s, e) =>
            {
                double step = new[] { 0.1, 1, 10, 50 }[Math.Max(0, stepBox.SelectedIndex)];
                double feed = dz != 0 ? 300 : 3000;
                string axis = dz != 0 ? "Z" + Fmt(dz * step) : "X" + Fmt(dx * step) + " Y" + Fmt(dy * step);
                grbl.Send("$J=G91 G21 " + axis + " F" + feed.ToString(CultureInfo.InvariantCulture));
            };
            return b;
        }

        static string Fmt(double v) { return v.ToString("0.###", CultureInfo.InvariantCulture); }

        void BuildLayout()
        {
            var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, Padding = new Padding(10) };
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

            // Job header
            var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 3, AutoSize = true };
            header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var jobText = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(8, 0, 0, 0) };
            jobText.Controls.Add(jobTitle);
            jobText.Controls.Add(jobSummary);
            header.Controls.Add(openButton, 0, 0);
            header.Controls.Add(jobText, 1, 0);
            header.Controls.Add(cameraButton, 2, 0);
            root.Controls.Add(header);

            // Machine settings
            var machine = new GroupBox { Text = "Connection", Dock = DockStyle.Fill, AutoSize = true };
            var grid = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, AutoSize = true, Padding = new Padding(4) };
            grid.Controls.Add(new Label { Text = "Machine type:", AutoSize = true, Anchor = AnchorStyles.Left }, 0, 0);
            grid.Controls.Add(kindBox, 1, 0);
            grid.Controls.Add(outputLabel, 2, 0);
            grid.Controls.Add(outputBox, 3, 0);
            var portRow = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = Padding.Empty };
            portRow.Controls.Add(portBox);
            portRow.Controls.Add(refreshButton);
            grid.Controls.Add(portLabel, 0, 1);
            grid.Controls.Add(portRow, 1, 1);
            grid.Controls.Add(baudLabel, 2, 1);
            grid.Controls.Add(baudBox, 3, 1);
            grid.Controls.Add(printerLabel, 0, 2);
            grid.Controls.Add(printerBox, 1, 2);
            grid.Controls.Add(flowLabel, 2, 2);
            grid.Controls.Add(flowBox, 3, 2);
            machine.Controls.Add(grid);
            root.Controls.Add(machine);

            // GRBL controls
            var g = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, AutoSize = true, Padding = new Padding(4) };
            g.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            g.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var left = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
            var buttons = new FlowLayoutPanel { AutoSize = true, WrapContents = true };
            buttons.Controls.AddRange(new Control[] { connectButton, homeButton, unlockButton, originButton, goOriginButton });
            left.Controls.Add(buttons);
            left.Controls.Add(statusLabel);
            var jog = new TableLayoutPanel { ColumnCount = 5, RowCount = 3, AutoSize = true };
            jog.Controls.Add(jogButtons[0], 1, 0);
            jog.Controls.Add(jogButtons[1], 0, 1);
            jog.Controls.Add(jogButtons[2], 2, 1);
            jog.Controls.Add(jogButtons[3], 1, 2);
            jog.Controls.Add(jogButtons[4], 4, 0);
            jog.Controls.Add(jogButtons[5], 4, 2);
            jog.Controls.Add(new Label { Text = "Step", AutoSize = true, Anchor = AnchorStyles.Bottom }, 3, 0);
            stepBox.Width = 80;
            jog.Controls.Add(stepBox, 3, 1);
            g.Controls.Add(left, 0, 0);
            g.Controls.Add(jog, 1, 0);
            grblGroup.Controls.Add(g);
            root.Controls.Add(grblGroup);

            // Run row
            var run = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 4, AutoSize = true };
            run.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            run.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            run.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            run.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            run.Controls.Add(startButton, 0, 0);
            run.Controls.Add(pauseButton, 1, 0);
            run.Controls.Add(stopButton, 2, 0);
            progress.Margin = new Padding(8, 6, 0, 6);
            run.Controls.Add(progress, 3, 0);
            root.Controls.Add(run);

            root.Controls.Add(log);
            Controls.Add(root);
        }

        void WireEvents()
        {
            openButton.Click += (s, e) =>
            {
                using (var dlg = new OpenFileDialog { Filter = Job.OpenFilter, Title = "Open a job" })
                {
                    if (!string.IsNullOrEmpty(settings.LastFolder) && Directory.Exists(settings.LastFolder))
                        dlg.InitialDirectory = settings.LastFolder;
                    if (dlg.ShowDialog(this) == DialogResult.OK) OpenJob(dlg.FileName);
                }
            };
            cameraButton.Click += (s, e) => ShowCamera();
            DragEnter += (s, e) => { if (e.Data.GetDataPresent(DataFormats.FileDrop)) e.Effect = DragDropEffects.Copy; };
            DragDrop += (s, e) =>
            {
                var files = e.Data.GetData(DataFormats.FileDrop) as string[];
                if (files != null && files.Length > 0) OpenJob(files[0]);
            };

            kindBox.SelectedIndexChanged += (s, e) => { UpdateMachineFields(); UpdateButtons(); };
            outputBox.SelectedIndexChanged += (s, e) => { UpdateMachineFields(); UpdateButtons(); };
            refreshButton.Click += (s, e) => RefreshPorts();
            portBox.SelectedIndexChanged += (s, e) => UpdateButtons();
            printerBox.SelectedIndexChanged += (s, e) => UpdateButtons();

            connectButton.Click += (s, e) => ToggleConnection();
            homeButton.Click += (s, e) => grbl.Send("$H");
            unlockButton.Click += (s, e) => grbl.Send("$X");
            originButton.Click += (s, e) => grbl.Send(IsCnc ? "G10 L20 P1 X0 Y0 Z0" : "G10 L20 P1 X0 Y0");
            goOriginButton.Click += (s, e) => grbl.Send("$J=G90 G21 X0 Y0 F3000");

            startButton.Click += (s, e) => StartJob();
            pauseButton.Click += (s, e) =>
            {
                if (grbl.IsPaused) grbl.Resume(); else grbl.Pause();
                UpdateButtons();
            };
            stopButton.Click += (s, e) =>
            {
                if (IsCutter) cutter.Cancel(); else grbl.Stop();
                UpdateButtons();
            };

            grbl.Log += Append;
            grbl.StatusChanged += text => { statusLabel.Text = text; };
            grbl.Progress += f => SetProgress(f);
            grbl.JobFinished += msg => UpdateButtons();
            grbl.Disconnected += () => UpdateButtons();

            cutter.Progress += f => SetProgress(f);
            cutter.Finished += (msg, isError) => { Append(msg, isError); UpdateButtons(); };

            FormClosing += (s, e) =>
            {
                if ((grbl.IsRunning || cutter.IsSending) &&
                    MessageBox.Show(this, "A job is still running. Stop it and quit?", "KerfSender",
                                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes)
                {
                    e.Cancel = true;
                    return;
                }
                if (grbl.IsRunning) grbl.Realtime(0x18);
                cutter.Cancel();
                SaveSettings();
                if (cameraForm != null) cameraForm.Dispose();
                grbl.Dispose();
            };
        }

        bool IsCutter { get { return kindBox.SelectedIndex >= 2; } }
        bool IsCnc { get { return kindBox.SelectedIndex == 1; } }
        bool UsesPrinter { get { return IsCutter && outputBox.SelectedIndex == 1; } }

        void OpenJob(string path)
        {
            if (grbl.IsRunning || cutter.IsSending)
            {
                MessageBox.Show(this, "Wait for the current job to finish, or stop it, before opening another.", "KerfSender");
                return;
            }
            Job loaded;
            try
            {
                loaded = Job.Load(path);
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Could not open " + Path.GetFileName(path) + ".\n\n" + ex.Message, "KerfSender",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            job = loaded;
            settings.LastFolder = Path.GetDirectoryName(path);
            jobTitle.Text = job.Name;
            jobSummary.Text = job.Summary();
            Text = job.Name + " — KerfSender";

            if (grbl.IsConnected && !job.UsesGrbl) grbl.Close();
            switch (job.Kind)
            {
                case MachineKind.GrblLaser: kindBox.SelectedIndex = 0; break;
                case MachineKind.CncRouter: kindBox.SelectedIndex = 1; break;
                default: kindBox.SelectedIndex = job.Language == "gpgl" ? 3 : 2; break;
            }
            outputBox.SelectedIndex = job.Output == CutterOutput.Printer ? 1 : 0;
            flowBox.SelectedIndex = job.FlowControl == "hardware" ? 1 : job.FlowControl == "software" ? 2 : 0;
            if (!grbl.IsConnected) baudBox.Text = job.BaudRate.ToString(CultureInfo.InvariantCulture);
            SetProgress(0);
            Append("Opened " + Path.GetFileName(path) + ": " + job.Summary(), false);
            if (!job.FromKerfKutter)
                Append("This is a plain file, so check the machine type and connection settings before starting.", false);
            UpdateMachineFields();
            UpdateButtons();
            if (cameraForm != null) cameraForm.JobOpened(job);
        }

        void ShowCamera()
        {
            if (cameraForm == null || cameraForm.IsDisposed)
            {
                cameraForm = new CameraForm(grbl, () => job, () => kindBox.SelectedIndex == 0, Append);
                cameraForm.JobOpened(job);
            }
            if (!cameraForm.Visible) cameraForm.Show(this);
            cameraForm.Activate();
        }

        void RefreshPorts()
        {
            string current = portBox.SelectedItem as string ?? settings.Port;
            portBox.Items.Clear();
            var ports = SerialPort.GetPortNames().Distinct().OrderBy(p => p.Length).ThenBy(p => p).ToArray();
            portBox.Items.AddRange(ports);
            if (current != null && ports.Contains(current)) portBox.SelectedItem = current;
            else if (ports.Length > 0) portBox.SelectedIndex = ports.Length - 1; // USB adapters usually get the highest number

            string printer = printerBox.SelectedItem as string ?? settings.Printer;
            printerBox.Items.Clear();
            var printers = RawPrinter.InstalledPrinters();
            printerBox.Items.AddRange(printers.ToArray());
            if (printer != null && printers.Contains(printer)) printerBox.SelectedItem = printer;
            UpdateButtons();
        }

        void UpdateMachineFields()
        {
            bool cutterKind = IsCutter;
            outputLabel.Visible = outputBox.Visible = cutterKind;
            flowLabel.Visible = flowBox.Visible = cutterKind && !UsesPrinter;
            printerLabel.Visible = printerBox.Visible = UsesPrinter;
            portLabel.Visible = portBox.Visible = refreshButton.Visible = !UsesPrinter;
            baudLabel.Visible = baudBox.Visible = !UsesPrinter;
            grblGroup.Visible = !cutterKind;
            cameraButton.Visible = !cutterKind;
            jogButtons[4].Visible = jogButtons[5].Visible = IsCnc;
            if (cutterKind && grbl.IsConnected) grbl.Close();
        }

        void UpdateButtons()
        {
            bool running = grbl.IsRunning || cutter.IsSending;
            bool connected = grbl.IsConnected;
            bool haveJob = job != null && job.Data.Length > 0;

            connectButton.Text = connected ? "Disconnect" : "Connect";
            connectButton.Enabled = !running && (connected || portBox.SelectedItem != null);
            foreach (var b in new[] { homeButton, unlockButton, originButton, goOriginButton })
                b.Enabled = connected && !running;
            foreach (var b in jogButtons) b.Enabled = connected && !running;

            kindBox.Enabled = outputBox.Enabled = flowBox.Enabled = !running;
            portBox.Enabled = refreshButton.Enabled = printerBox.Enabled = !running && !connected;
            baudBox.Enabled = !running && !connected;
            openButton.Enabled = !running;

            if (IsCutter)
            {
                bool target = UsesPrinter ? printerBox.SelectedItem != null : portBox.SelectedItem != null;
                startButton.Text = "Send to cutter";
                startButton.Enabled = haveJob && !running && target;
                pauseButton.Visible = false;
                stopButton.Enabled = cutter.IsSending;
            }
            else
            {
                startButton.Text = "Start";
                startButton.Enabled = haveJob && connected && !running;
                pauseButton.Visible = true;
                pauseButton.Enabled = grbl.IsRunning;
                pauseButton.Text = grbl.IsPaused ? "Resume" : "Pause";
                stopButton.Enabled = connected;
            }
            if (cameraForm != null && !cameraForm.IsDisposed) cameraForm.MachineChanged();
        }

        void ToggleConnection()
        {
            if (grbl.IsConnected)
            {
                grbl.Close();
                UpdateButtons();
                return;
            }
            string port = portBox.SelectedItem as string;
            if (port == null) return;
            try
            {
                grbl.Open(port, ParseBaud(115200), job != null && job.UsesGrbl ? job.RxBufferSize : 127);
                settings.Port = port;
            }
            catch (Exception ex)
            {
                Append("Could not open " + port + ": " + ex.Message, true);
            }
            UpdateButtons();
        }

        int ParseBaud(int fallback)
        {
            int baud;
            return int.TryParse(baudBox.Text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out baud) && baud > 0 ? baud : fallback;
        }

        void StartJob()
        {
            if (job == null) return;
            SetProgress(0);
            if (IsCutter)
            {
                if (job.UsesGrbl &&
                    MessageBox.Show(this, "This job is G-code, but the machine type is a vinyl cutter. Send it anyway?", "KerfSender",
                                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
                byte[] data = Encoding.ASCII.GetBytes(job.Data);
                if (UsesPrinter)
                {
                    string printer = printerBox.SelectedItem as string;
                    settings.Printer = printer;
                    Append("Sending " + data.Length.ToString("N0") + " bytes to printer " + printer + "…", false);
                    cutter.SendToPrinter(data, printer, "KerfSender " + job.Name);
                }
                else
                {
                    string port = portBox.SelectedItem as string;
                    settings.Port = port;
                    string flow = flowBox.SelectedIndex == 1 ? "hardware" : flowBox.SelectedIndex == 2 ? "software" : "none";
                    Append("Sending " + data.Length.ToString("N0") + " bytes to " + port + "…", false);
                    cutter.SendSerial(data, port, ParseBaud(9600), flow);
                }
            }
            else
            {
                if (!job.UsesGrbl &&
                    MessageBox.Show(this, "This job is plotter data, not G-code. Send it to the GRBL machine anyway?", "KerfSender",
                                    MessageBoxButtons.YesNo, MessageBoxIcon.Warning) != DialogResult.Yes) return;
                if (grbl.State != null && grbl.State.StartsWith("Alarm"))
                {
                    MessageBox.Show(this, "The machine is in an alarm state. Home it, or Unlock it, before starting.", "KerfSender",
                                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                var lines = job.GcodeLines();
                if (cameraForm != null && !cameraForm.IsDisposed && cameraForm.PlacementActive)
                {
                    string error;
                    var placed = cameraForm.PlacedLines(job, out error);
                    if (placed == null)
                    {
                        MessageBox.Show(this, error, "KerfSender", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                        return;
                    }
                    Append("Running the job as placed with the camera: " + cameraForm.PlacementDescription + ".", false);
                    lines = placed;
                }
                grbl.Run(lines);
            }
            UpdateButtons();
        }

        void SetProgress(double fraction)
        {
            progress.Value = (int)Math.Round(Math.Max(0, Math.Min(1, fraction)) * progress.Maximum);
        }

        void Append(string text, bool isError)
        {
            string line = DateTime.Now.ToString("HH:mm:ss") + "  " + (isError ? "! " : "") + text + Environment.NewLine;
            if (log.TextLength > 200000) log.Text = log.Text.Substring(log.TextLength - 100000);
            log.AppendText(line);
        }

        void SaveSettings()
        {
            if (portBox.SelectedItem != null) settings.Port = (string)portBox.SelectedItem;
            if (printerBox.SelectedItem != null) settings.Printer = (string)printerBox.SelectedItem;
            settings.Save();
        }
    }

    /// <summary>Remembers the last port, printer and folder in %APPDATA%\KerfSender\settings.txt.</summary>
    public sealed class Settings
    {
        public string Port, Printer, LastFolder;

        static string FilePath
        {
            get { return Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "KerfSender"), "settings.txt"); }
        }

        public static Settings Load()
        {
            var s = new Settings();
            try
            {
                if (!File.Exists(FilePath)) return s;
                foreach (string line in File.ReadAllLines(FilePath))
                {
                    int eq = line.IndexOf('=');
                    if (eq < 0) continue;
                    string key = line.Substring(0, eq), value = line.Substring(eq + 1);
                    if (key == "port") s.Port = value;
                    else if (key == "printer") s.Printer = value;
                    else if (key == "folder") s.LastFolder = value;
                }
            }
            catch (Exception) { }
            return s;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath));
                File.WriteAllLines(FilePath, new[] { "port=" + Port, "printer=" + Printer, "folder=" + LastFolder });
            }
            catch (Exception) { }
        }
    }
}
