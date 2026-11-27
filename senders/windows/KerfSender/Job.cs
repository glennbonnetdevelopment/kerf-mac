using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;

namespace KerfSender
{
    public enum MachineKind { GrblLaser, CncRouter, VinylCutter }

    public enum CutterOutput { Serial, Printer }

    /// <summary>A job to send: a .kerfjob from KerfKutter, or a plain G-code / HPGL file.</summary>
    public sealed class Job
    {
        public const int SupportedVersion = 1;

        public string Name;
        public string FilePath;
        public string MachineName;
        public MachineKind Kind;
        public string Language = "gcode"; // gcode, hpgl, gpgl
        public int BaudRate = 115200;
        public string FlowControl = "none"; // none, hardware, software
        public int RxBufferSize = 127;
        public CutterOutput Output = CutterOutput.Serial;
        public double BedWidth, BedHeight;
        public int EstimatedSeconds;
        public string Data = "";
        /// <summary>True when the machine settings came from KerfKutter rather than a guess.</summary>
        public bool FromKerfKutter;

        public bool UsesGrbl { get { return Kind != MachineKind.VinylCutter; } }

        public static readonly string OpenFilter =
            "KerfKutter jobs and machine files|*.kerfjob;*.gc;*.gcode;*.nc;*.ngc;*.tap;*.plt;*.hpgl;*.hpg|" +
            "KerfKutter jobs (*.kerfjob)|*.kerfjob|" +
            "G-code (*.gc, *.gcode, *.nc)|*.gc;*.gcode;*.nc;*.ngc;*.tap|" +
            "Plotter files (*.plt, *.hpgl)|*.plt;*.hpgl;*.hpg|" +
            "All files|*.*";

        public static Job Load(string path)
        {
            string text = File.ReadAllText(path, Encoding.UTF8);
            string ext = Path.GetExtension(path).ToLowerInvariant();
            Job job;
            if (ext == ".kerfjob" || text.TrimStart('﻿', ' ', '\r', '\n', '\t').StartsWith("{"))
                job = FromKerfJob(text);
            else
                job = FromPlainFile(text, ext);
            job.FilePath = path;
            if (string.IsNullOrEmpty(job.Name)) job.Name = Path.GetFileNameWithoutExtension(path);
            return job;
        }

        static Job FromKerfJob(string text)
        {
            var root = Json.Parse(text) as Dictionary<string, object>;
            if (root == null || Str(root, "format") != "kerfjob")
                throw new FormatException("This is not a KerfKutter job file.");
            int version = Int(root, "version", 1);
            if (version > SupportedVersion)
                throw new FormatException("This job was made by a newer KerfKutter (job format " + version +
                                          "). Please update KerfSender.");
            var job = new Job { FromKerfKutter = true };
            job.Name = Str(root, "name");
            job.EstimatedSeconds = Int(root, "estimatedSeconds", 0);
            job.Data = Str(root, "data") ?? "";
            var m = root.ContainsKey("machine") ? root["machine"] as Dictionary<string, object> : null;
            if (m == null) throw new FormatException("The job file has no machine settings.");
            job.MachineName = Str(m, "name") ?? "Machine";
            switch (Str(m, "kind"))
            {
                case "grblLaser": job.Kind = MachineKind.GrblLaser; break;
                case "cncRouter": job.Kind = MachineKind.CncRouter; break;
                case "vinylCutter": job.Kind = MachineKind.VinylCutter; break;
                default: throw new FormatException("Unknown machine type '" + Str(m, "kind") + "'.");
            }
            job.Language = Str(m, "language") ?? (job.UsesGrbl ? "gcode" : "hpgl");
            job.BaudRate = Int(m, "baudRate", job.UsesGrbl ? 115200 : 9600);
            job.FlowControl = Str(m, "flowControl") ?? "none";
            job.RxBufferSize = Int(m, "rxBufferSize", 127);
            job.Output = Str(m, "output") == "printerQueue" ? CutterOutput.Printer : CutterOutput.Serial;
            job.BedWidth = Num(m, "bedWidth", 0);
            job.BedHeight = Num(m, "bedHeight", 0);
            return job;
        }

        static Job FromPlainFile(string text, string ext)
        {
            var job = new Job { Data = text };
            bool plotter = ext == ".plt" || ext == ".hpgl" || ext == ".hpg" || LooksLikeHpgl(text);
            if (plotter)
            {
                job.Kind = MachineKind.VinylCutter;
                job.Language = "hpgl";
                job.MachineName = "Vinyl cutter";
                job.BaudRate = 9600;
                job.FlowControl = "software";
            }
            else
            {
                job.Kind = MachineKind.GrblLaser;
                job.MachineName = "GRBL machine";
            }
            return job;
        }

        static bool LooksLikeHpgl(string text)
        {
            string head = text.Length > 200 ? text.Substring(0, 200) : text;
            head = head.TrimStart().ToUpperInvariant();
            return head.StartsWith("IN;") || head.StartsWith("IN ") || head.StartsWith("PU") || head.StartsWith("\u001B.");
        }

        /// <summary>G-code lines to stream, with comments and blank lines removed.</summary>
        public List<string> GcodeLines()
        {
            var result = new List<string>();
            foreach (string raw in Data.Split('\n'))
            {
                string clean = GrblStreamer.Clean(raw);
                if (clean != null) result.Add(clean);
            }
            return result;
        }

        public string Summary()
        {
            var sb = new StringBuilder();
            sb.Append(MachineName);
            if (UsesGrbl) sb.Append(" · ").Append(GcodeLines().Count.ToString("N0")).Append(" lines");
            else sb.Append(" · ").Append(Language.ToUpperInvariant()).Append(" · ").Append(Data.Length.ToString("N0")).Append(" bytes");
            if (EstimatedSeconds > 0) sb.Append(" · about ").Append(FormatDuration(EstimatedSeconds));
            if (!FromKerfKutter) sb.Append(" · plain file, check the settings below");
            return sb.ToString();
        }

        public static string FormatDuration(int seconds)
        {
            if (seconds < 60) return seconds + " s";
            if (seconds < 3600) return (seconds / 60) + " min " + (seconds % 60) + " s";
            return (seconds / 3600) + " h " + (seconds % 3600 / 60) + " min";
        }

        static string Str(Dictionary<string, object> d, string key)
        {
            object v;
            return d.TryGetValue(key, out v) ? v as string : null;
        }

        static double Num(Dictionary<string, object> d, string key, double fallback)
        {
            object v;
            return d.TryGetValue(key, out v) && v is double ? (double)v : fallback;
        }

        static int Int(Dictionary<string, object> d, string key, int fallback)
        {
            return (int)Math.Round(Num(d, key, fallback), MidpointRounding.AwayFromZero);
        }
    }
}
