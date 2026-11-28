using System;
using System.IO;
using KerfSender;

static class SelfTest
{
    static int failures;

    static void Check(bool ok, string what)
    {
        Console.WriteLine((ok ? "ok   " : "FAIL ") + what);
        if (!ok) failures++;
    }

    static int Main()
    {
        string root = FindSamples();

        var laser = Job.Load(Path.Combine(root, "laser-square.kerfjob"));
        Check(laser.FromKerfKutter, "laser job is recognised as a KerfKutter job");
        Check(laser.Kind == MachineKind.GrblLaser, "laser kind");
        Check(laser.BaudRate == 115200 && laser.RxBufferSize == 127, "laser serial settings");
        Check(laser.GcodeLines().Count == 9, "laser G-code lines without comments: " + laser.GcodeLines().Count);
        Check(laser.MachineName == "xTool D1 Pro", "machine name");

        var cutter = Job.Load(Path.Combine(root, "cutter-square.kerfjob"));
        Check(cutter.Kind == MachineKind.VinylCutter && cutter.Language == "hpgl", "cutter kind and language");
        Check(cutter.Output == CutterOutput.Printer && cutter.FlowControl == "hardware", "cutter output and flow control");
        Check(cutter.Data.StartsWith("IN;"), "cutter data");

        var plain = Job.Load(Path.Combine(root, "plain.plt"));
        Check(plain.Kind == MachineKind.VinylCutter && !plain.FromKerfKutter, "plain .plt is treated as a cutter file");

        try { Job.Load(Path.Combine(root, "future.kerfjob")); Check(false, "newer format is refused"); }
        catch (FormatException) { Check(true, "newer format is refused"); }

        var s = new GrblStreamer(20);
        s.Enqueue(new[] { "G1 X10 Y10 ; move", "(note)", "G1 X20", "G1 X30 Y30 F100" });
        Check(s.Total == 3, "streamer drops comments");
        var first = s.TakeSendable();
        Check(first.Count == 2, "streamer fills the 20-byte buffer with 2 lines: " + first.Count);
        Check(s.TakeSendable().Count == 0, "streamer waits while full");
        s.Acknowledge(false);
        Check(s.TakeSendable().Count == 0, "16-byte line still waits with 7 bytes in the buffer");
        s.Acknowledge(false);
        Check(s.TakeSendable().Count == 1, "streamer sends the next line once it fits");
        s.Acknowledge(true);
        Check(s.IsIdle && s.Errors == 1 && s.Acknowledged == 3, "streamer finishes and counts errors");

        CameraTests.Run(Check);

        Console.WriteLine(failures == 0 ? "All checks passed." : failures + " check(s) failed.");
        return failures == 0 ? 0 : 1;
    }

    static string FindSamples()
    {
        string d = AppContext.BaseDirectory;
        while (d != null && !Directory.Exists(Path.Combine(d, "senders", "samples"))) d = Path.GetDirectoryName(d);
        if (d == null) throw new DirectoryNotFoundException("senders/samples not found");
        return Path.Combine(d, "senders", "samples");
    }
}
