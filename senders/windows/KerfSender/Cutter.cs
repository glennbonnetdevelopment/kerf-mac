using System;
using System.Collections.Generic;
using System.IO.Ports;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace KerfSender
{
    /// <summary>Sends HPGL / GP-GL to a vinyl cutter over a serial port or a Windows printer, on a background thread.</summary>
    public sealed class CutterSender
    {
        public event Action<double> Progress;   // 0..1, on the UI thread
        public event Action<string, bool> Finished; // message, isError, on the UI thread

        readonly SynchronizationContext ui;
        volatile bool cancel;
        public bool IsSending { get; private set; }

        public CutterSender()
        {
            ui = SynchronizationContext.Current ?? new SynchronizationContext();
        }

        public void Cancel() { cancel = true; }

        public void SendSerial(byte[] data, string portName, int baud, string flowControl)
        {
            if (IsSending) return;
            IsSending = true;
            cancel = false;
            var thread = new Thread(() =>
            {
                string outcome = "Sent " + data.Length.ToString("N0") + " bytes to " + portName + ".";
                bool isError = false;
                SerialPort port = null;
                try
                {
                    port = new SerialPort(portName, baud, Parity.None, 8, StopBits.One);
                    port.Handshake = flowControl == "hardware" ? Handshake.RequestToSend
                                   : flowControl == "software" ? Handshake.XOnXOff : Handshake.None;
                    port.DtrEnable = true;
                    if (port.Handshake != Handshake.RequestToSend) port.RtsEnable = true;
                    port.WriteTimeout = 60000; // the cutter may hold us off while it cuts
                    port.WriteBufferSize = 4096;
                    port.Open();
                    int offset = 0;
                    while (offset < data.Length)
                    {
                        if (cancel)
                        {
                            outcome = "Stopped. The cutter may finish the commands already in its buffer.";
                            break;
                        }
                        int n = Math.Min(256, data.Length - offset);
                        port.Write(data, offset, n);
                        offset += n;
                        // Keep the progress bar honest: wait for the driver to hand the bytes on.
                        while (port.BytesToWrite > 512 && !cancel) Thread.Sleep(20);
                        double fraction = (double)offset / data.Length;
                        ui.Post(_ => { if (Progress != null) Progress(fraction); }, null);
                    }
                    var deadline = DateTime.Now.AddSeconds(120);
                    while (!cancel && port.BytesToWrite > 0 && DateTime.Now < deadline) Thread.Sleep(50);
                }
                catch (TimeoutException)
                {
                    outcome = "The cutter stopped accepting data. Check it is online, and the baud rate and flow control.";
                    isError = true;
                }
                catch (Exception ex)
                {
                    outcome = ex.Message;
                    isError = true;
                }
                finally
                {
                    if (port != null) { try { port.Close(); } catch { } port.Dispose(); }
                }
                ui.Post(_ =>
                {
                    IsSending = false;
                    if (Finished != null) Finished(outcome, isError);
                }, null);
            });
            thread.IsBackground = true;
            thread.Start();
        }

        public void SendToPrinter(byte[] data, string printerName, string docName)
        {
            if (IsSending) return;
            IsSending = true;
            cancel = false;
            var thread = new Thread(() =>
            {
                string error = RawPrinter.Send(printerName, docName, data);
                ui.Post(_ =>
                {
                    IsSending = false;
                    if (error == null && Progress != null) Progress(1);
                    if (Finished != null)
                        Finished(error ?? "Sent to printer " + printerName + ".", error != null);
                }, null);
            });
            thread.IsBackground = true;
            thread.Start();
        }
    }

    /// <summary>Writes raw bytes to a Windows printer, bypassing the driver's rendering (like "lp -o raw").</summary>
    public static class RawPrinter
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        class DOCINFO
        {
            [MarshalAs(UnmanagedType.LPWStr)] public string pDocName;
            [MarshalAs(UnmanagedType.LPWStr)] public string pOutputFile;
            [MarshalAs(UnmanagedType.LPWStr)] public string pDataType;
        }

        [DllImport("winspool.drv", EntryPoint = "OpenPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern bool OpenPrinter(string name, out IntPtr handle, IntPtr defaults);

        [DllImport("winspool.drv", SetLastError = true)]
        static extern bool ClosePrinter(IntPtr handle);

        [DllImport("winspool.drv", EntryPoint = "StartDocPrinterW", SetLastError = true, CharSet = CharSet.Unicode)]
        static extern int StartDocPrinter(IntPtr handle, int level, [In] DOCINFO info);

        [DllImport("winspool.drv", SetLastError = true)]
        static extern bool EndDocPrinter(IntPtr handle);

        [DllImport("winspool.drv", SetLastError = true)]
        static extern bool StartPagePrinter(IntPtr handle);

        [DllImport("winspool.drv", SetLastError = true)]
        static extern bool EndPagePrinter(IntPtr handle);

        [DllImport("winspool.drv", SetLastError = true)]
        static extern bool WritePrinter(IntPtr handle, IntPtr bytes, int count, out int written);

        public static List<string> InstalledPrinters()
        {
            var list = new List<string>();
            try
            {
                foreach (string p in System.Drawing.Printing.PrinterSettings.InstalledPrinters) list.Add(p);
            }
            catch (Exception) { }
            return list;
        }

        /// <summary>Returns an error message, or null on success.</summary>
        public static string Send(string printerName, string docName, byte[] data)
        {
            if (string.IsNullOrEmpty(printerName)) return "Choose a printer first.";
            IntPtr h;
            if (!OpenPrinter(printerName, out h, IntPtr.Zero))
                return "Could not open printer " + printerName + " (Windows error " + Marshal.GetLastWin32Error() + ").";
            IntPtr buffer = IntPtr.Zero;
            try
            {
                var info = new DOCINFO { pDocName = docName, pDataType = "RAW" };
                if (StartDocPrinter(h, 1, info) == 0)
                    return "The printer refused the job (Windows error " + Marshal.GetLastWin32Error() + ").";
                try
                {
                    if (!StartPagePrinter(h)) return "The printer refused the page (Windows error " + Marshal.GetLastWin32Error() + ").";
                    buffer = Marshal.AllocCoTaskMem(data.Length);
                    Marshal.Copy(data, 0, buffer, data.Length);
                    int written;
                    bool ok = WritePrinter(h, buffer, data.Length, out written);
                    EndPagePrinter(h);
                    if (!ok || written != data.Length)
                        return "Only " + written + " of " + data.Length + " bytes reached the printer (Windows error " +
                               Marshal.GetLastWin32Error() + ").";
                }
                finally
                {
                    EndDocPrinter(h);
                }
                return null;
            }
            finally
            {
                if (buffer != IntPtr.Zero) Marshal.FreeCoTaskMem(buffer);
                ClosePrinter(h);
            }
        }
    }
}
