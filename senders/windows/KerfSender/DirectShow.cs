using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

// USB camera capture through DirectShow, which every Windows from 7 to 11 has and which needs no extra
// download (Media Foundation's capture API is incomplete on Windows 7). The graph is
// camera → Sample Grabber (24-bit RGB) → Null Renderer; frames are read by polling the grabber's buffer.

namespace KerfSender
{
    public sealed class CameraDevice
    {
        public string Name;
        /// <summary>Stable id for remembering the calibration (the device path, or the name when there is none).</summary>
        public string Id;
        internal IMoniker Moniker;
        public override string ToString() { return Name; }
    }

    /// <summary>One captured picture: 24-bit BGR, rows top to bottom, packed (stride = width × 3).</summary>
    public sealed class CameraFrame
    {
        public int Width, Height;
        public byte[] Bgr;
        public DateTime Time;
        GrayImage gray;
        public GrayImage Gray { get { return gray ?? (gray = GrayImage.FromBgr24(Bgr, Width, Height, Width * 3, false)); } }
    }

    public sealed class CameraCapture : IDisposable
    {
        IGraphBuilder graph;
        IMediaControl control;
        ISampleGrabber grabber;
        object source, grabberFilter, nullRenderer;
        byte[] buffer;
        int stride;
        bool bottomUp = true;

        public int Width { get; private set; }
        public int Height { get; private set; }
        public bool IsRunning { get { return control != null; } }

        public static List<CameraDevice> Devices()
        {
            var list = new List<CameraDevice>();
            ICreateDevEnum devEnum = null;
            IEnumMoniker em = null;
            try
            {
                devEnum = (ICreateDevEnum)Activator.CreateInstance(Type.GetTypeFromCLSID(Clsid.SystemDeviceEnum));
                Guid cat = Clsid.VideoInputDeviceCategory;
                if (devEnum.CreateClassEnumerator(ref cat, out em, 0) != 0 || em == null) return list;
                var m = new IMoniker[1];
                while (em.Next(1, m, IntPtr.Zero) == 0)
                {
                    string name = Property(m[0], "FriendlyName") ?? "Camera";
                    string path = Property(m[0], "DevicePath");
                    list.Add(new CameraDevice { Name = name, Id = string.IsNullOrEmpty(path) ? name : path, Moniker = m[0] });
                }
            }
            catch (Exception) { }
            finally
            {
                if (em != null) Marshal.ReleaseComObject(em);
                if (devEnum != null) Marshal.ReleaseComObject(devEnum);
            }
            // Two identical cameras get the same name; number them so they can be told apart.
            var seen = new Dictionary<string, int>();
            foreach (var d in list)
            {
                int n;
                seen.TryGetValue(d.Name, out n);
                seen[d.Name] = n + 1;
                if (n > 0) d.Name += " (" + (n + 1) + ")";
            }
            return list;
        }

        static string Property(IMoniker m, string key)
        {
            object bagObj = null;
            try
            {
                Guid iid = typeof(IPropertyBag).GUID;
                m.BindToStorage(null, null, ref iid, out bagObj);
                var bag = (IPropertyBag)bagObj;
                object val;
                if (bag.Read(key, out val, IntPtr.Zero) != 0) return null;
                return val as string;
            }
            catch (Exception) { return null; }
            finally { if (bagObj != null) Marshal.ReleaseComObject(bagObj); }
        }

        /// <summary>Starts the camera at its largest picture up to `maxWidth`×`maxHeight`. Throws with a readable message on failure.</summary>
        public void Start(CameraDevice device, int maxWidth, int maxHeight)
        {
            Stop();
            try
            {
                graph = (IGraphBuilder)Activator.CreateInstance(Type.GetTypeFromCLSID(Clsid.FilterGraph));
                var builder = (ICaptureGraphBuilder2)Activator.CreateInstance(Type.GetTypeFromCLSID(Clsid.CaptureGraphBuilder2));
                Check(builder.SetFiltergraph(graph), "set up the capture graph");

                Guid iidFilter = typeof(IBaseFilter).GUID;
                device.Moniker.BindToObject(null, null, ref iidFilter, out source);
                Check(graph.AddFilter((IBaseFilter)source, "Camera"), "add the camera");

                grabberFilter = Activator.CreateInstance(Type.GetTypeFromCLSID(Clsid.SampleGrabber));
                grabber = (ISampleGrabber)grabberFilter;
                var mt = new AMMediaType { majorType = MediaType.Video, subType = MediaSubType.RGB24, formatType = FormatType.VideoInfo };
                Check(grabber.SetMediaType(mt), "ask for RGB pictures");
                Check(graph.AddFilter((IBaseFilter)grabberFilter, "Grabber"), "add the frame grabber");
                nullRenderer = Activator.CreateInstance(Type.GetTypeFromCLSID(Clsid.NullRenderer));
                Check(graph.AddFilter((IBaseFilter)nullRenderer, "Null"), "add the renderer");

                PickLargestFormat(builder, source, maxWidth, maxHeight);

                Guid cat = PinCategory.Capture, med = MediaType.Video;
                int hr = builder.RenderStream(ref cat, ref med, source, (IBaseFilter)grabberFilter, (IBaseFilter)nullRenderer);
                if (hr < 0)
                {
                    // Some cameras only offer a preview pin.
                    cat = PinCategory.Preview;
                    hr = builder.RenderStream(ref cat, ref med, source, (IBaseFilter)grabberFilter, (IBaseFilter)nullRenderer);
                }
                Check(hr, "connect the camera");

                var connected = new AMMediaType();
                Check(grabber.GetConnectedMediaType(connected), "read the picture size");
                try
                {
                    if (connected.formatType != FormatType.VideoInfo || connected.formatPtr == IntPtr.Zero)
                        throw new InvalidOperationException("The camera didn't report its picture size.");
                    var vih = (VideoInfoHeader)Marshal.PtrToStructure(connected.formatPtr, typeof(VideoInfoHeader));
                    Width = vih.BmiHeader.Width;
                    Height = Math.Abs(vih.BmiHeader.Height);
                    bottomUp = vih.BmiHeader.Height > 0;
                    stride = (Width * 3 + 3) & ~3;
                }
                finally { FreeMediaType(connected); }
                Marshal.ReleaseComObject(builder);

                Check(grabber.SetBufferSamples(true), "keep frames");
                Check(grabber.SetOneShot(false), "stream frames");
                control = (IMediaControl)graph;
                hr = control.Run();
                if (hr < 0) { control = null; Check(hr, "start the camera"); }
            }
            catch
            {
                Stop();
                throw;
            }
        }

        /// <summary>Asks for the camera's largest picture that fits the limit, so calibration gets the most detail.</summary>
        static void PickLargestFormat(ICaptureGraphBuilder2 builder, object source, int maxWidth, int maxHeight)
        {
            object o = null;
            Guid cat = PinCategory.Capture, med = MediaType.Video, iid = typeof(IAMStreamConfig).GUID;
            if (builder.FindInterface(ref cat, ref med, (IBaseFilter)source, ref iid, out o) < 0 || o == null) return;
            var config = (IAMStreamConfig)o;
            try
            {
                int count, size;
                if (config.GetNumberOfCapabilities(out count, out size) < 0 || size <= 0) return;
                IntPtr caps = Marshal.AllocCoTaskMem(Math.Max(size, 256));
                try
                {
                    int bestIndex = -1;
                    long bestArea = 0;
                    for (int i = 0; i < count; i++)
                    {
                        IntPtr pmt;
                        if (config.GetStreamCaps(i, out pmt, caps) < 0 || pmt == IntPtr.Zero) continue;
                        var mt = (AMMediaType)Marshal.PtrToStructure(pmt, typeof(AMMediaType));
                        if (mt.formatType == FormatType.VideoInfo && mt.formatPtr != IntPtr.Zero)
                        {
                            var vih = (VideoInfoHeader)Marshal.PtrToStructure(mt.formatPtr, typeof(VideoInfoHeader));
                            int w = vih.BmiHeader.Width, h = Math.Abs(vih.BmiHeader.Height);
                            long area = (long)w * h;
                            if (w <= maxWidth && h <= maxHeight && area > bestArea) { bestArea = area; bestIndex = i; }
                        }
                        DeleteMediaType(pmt);
                    }
                    if (bestIndex >= 0)
                    {
                        IntPtr pmt;
                        if (config.GetStreamCaps(bestIndex, out pmt, caps) >= 0 && pmt != IntPtr.Zero)
                        {
                            var mt = (AMMediaType)Marshal.PtrToStructure(pmt, typeof(AMMediaType));
                            config.SetFormat(mt); // a failure here just leaves the camera's default size
                            DeleteMediaType(pmt);
                        }
                    }
                }
                finally { Marshal.FreeCoTaskMem(caps); }
            }
            catch (Exception) { }
            finally { Marshal.ReleaseComObject(config); }
        }

        /// <summary>The latest picture, or null when none has arrived yet.</summary>
        public CameraFrame Grab()
        {
            if (grabber == null || control == null) return null;
            int size = 0;
            if (grabber.GetCurrentBuffer(ref size, IntPtr.Zero) < 0 || size <= 0) return null;
            if (size < stride * Height) return null;
            IntPtr mem = Marshal.AllocCoTaskMem(size);
            try
            {
                if (grabber.GetCurrentBuffer(ref size, mem) < 0) return null;
                if (buffer == null || buffer.Length != size) buffer = new byte[size];
                Marshal.Copy(mem, buffer, 0, size);
            }
            finally { Marshal.FreeCoTaskMem(mem); }
            var packed = new byte[Width * Height * 3];
            int row = Width * 3;
            for (int y = 0; y < Height; y++)
            {
                int src = (bottomUp ? Height - 1 - y : y) * stride;
                Buffer.BlockCopy(buffer, src, packed, y * row, row);
            }
            return new CameraFrame { Width = Width, Height = Height, Bgr = packed, Time = DateTime.Now };
        }

        public void Stop()
        {
            if (control != null) { try { control.Stop(); } catch (Exception) { } }
            control = null;
            foreach (var o in new[] { nullRenderer, grabberFilter, source })
                if (o != null) { try { Marshal.ReleaseComObject(o); } catch (Exception) { } }
            nullRenderer = grabberFilter = source = null;
            grabber = null;
            if (graph != null) { try { Marshal.ReleaseComObject(graph); } catch (Exception) { } }
            graph = null;
            Width = Height = 0;
        }

        public void Dispose() { Stop(); }

        static void Check(int hr, string what)
        {
            if (hr < 0) throw new InvalidOperationException("Couldn't " + what + " (error 0x" + hr.ToString("X8") + "). Is the camera in use by another program?");
        }

        static void FreeMediaType(AMMediaType mt)
        {
            if (mt.formatSize != 0 && mt.formatPtr != IntPtr.Zero) Marshal.FreeCoTaskMem(mt.formatPtr);
            mt.formatSize = 0;
            mt.formatPtr = IntPtr.Zero;
            if (mt.unkPtr != IntPtr.Zero) { Marshal.Release(mt.unkPtr); mt.unkPtr = IntPtr.Zero; }
        }

        static void DeleteMediaType(IntPtr pmt)
        {
            var mt = (AMMediaType)Marshal.PtrToStructure(pmt, typeof(AMMediaType));
            FreeMediaType(mt);
            Marshal.FreeCoTaskMem(pmt);
        }
    }

    #region DirectShow interop

    static class Clsid
    {
        public static readonly Guid SystemDeviceEnum = new Guid("62BE5D10-60EB-11d0-BD3B-00A0C911CE86");
        public static readonly Guid VideoInputDeviceCategory = new Guid("860BB310-5D01-11d0-BD3B-00A0C911CE86");
        public static readonly Guid FilterGraph = new Guid("E436EBB3-524F-11CE-9F53-0020AF0BA770");
        public static readonly Guid CaptureGraphBuilder2 = new Guid("BF87B6E1-8C27-11d0-B3F0-00AA003761C5");
        public static readonly Guid SampleGrabber = new Guid("C1F400A0-3F08-11d3-9F0B-006008039E37");
        public static readonly Guid NullRenderer = new Guid("C1F400A4-3F08-11d3-9F0B-006008039E37");
    }

    static class MediaType { public static readonly Guid Video = new Guid("73646976-0000-0010-8000-00AA00389B71"); }
    static class MediaSubType { public static readonly Guid RGB24 = new Guid("e436eb7d-524f-11ce-9f53-0020af0ba770"); }
    static class FormatType { public static readonly Guid VideoInfo = new Guid("05589f80-c356-11ce-bf01-00aa0055595a"); }
    static class PinCategory
    {
        public static readonly Guid Capture = new Guid("fb6c4281-0353-11d1-905f-0000c0cc16ba");
        public static readonly Guid Preview = new Guid("fb6c4282-0353-11d1-905f-0000c0cc16ba");
    }

    [StructLayout(LayoutKind.Sequential)]
    class AMMediaType
    {
        public Guid majorType;
        public Guid subType;
        [MarshalAs(UnmanagedType.Bool)] public bool fixedSizeSamples;
        [MarshalAs(UnmanagedType.Bool)] public bool temporalCompression;
        public int sampleSize;
        public Guid formatType;
        public IntPtr unkPtr;
        public int formatSize;
        public IntPtr formatPtr;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    struct BitmapInfoHeader
    {
        public int Size, Width, Height;
        public short Planes, BitCount;
        public int Compression, ImageSize, XPelsPerMeter, YPelsPerMeter, ClrUsed, ClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct VideoInfoHeader
    {
        public RECT SrcRect, TargetRect;
        public int BitRate, BitErrorRate;
        public long AvgTimePerFrame;
        public BitmapInfoHeader BmiHeader;
    }

    [ComImport, Guid("29840822-5B84-11D0-BD3B-00A0C911CE86"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ICreateDevEnum
    {
        [PreserveSig] int CreateClassEnumerator([In] ref Guid type, [Out] out IEnumMoniker enumMoniker, [In] int flags);
    }

    [ComImport, Guid("55272A00-42CB-11CE-8135-00AA004BB851"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyBag
    {
        [PreserveSig] int Read([In, MarshalAs(UnmanagedType.LPWStr)] string propName, [Out, MarshalAs(UnmanagedType.Struct)] out object var, [In] IntPtr errorLog);
        [PreserveSig] int Write([In, MarshalAs(UnmanagedType.LPWStr)] string propName, [In, MarshalAs(UnmanagedType.Struct)] ref object var);
    }

    [ComImport, Guid("56a86895-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IBaseFilter
    {
        // IPersist
        [PreserveSig] int GetClassID(out Guid classID);
        // IMediaFilter
        [PreserveSig] int Stop();
        [PreserveSig] int Pause();
        [PreserveSig] int Run(long start);
        [PreserveSig] int GetState(int msTimeout, out int state);
        [PreserveSig] int SetSyncSource(IntPtr clock);
        [PreserveSig] int GetSyncSource(out IntPtr clock);
        // IBaseFilter
        [PreserveSig] int EnumPins(out IntPtr enumPins);
        [PreserveSig] int FindPin([MarshalAs(UnmanagedType.LPWStr)] string id, out IntPtr pin);
        [PreserveSig] int QueryFilterInfo(IntPtr info);
        [PreserveSig] int JoinFilterGraph(IntPtr graph, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int QueryVendorInfo([MarshalAs(UnmanagedType.LPWStr)] out string vendorInfo);
    }

    [ComImport, Guid("56a868a9-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IGraphBuilder
    {
        // IFilterGraph
        [PreserveSig] int AddFilter([In] IBaseFilter filter, [In, MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int RemoveFilter([In] IBaseFilter filter);
        [PreserveSig] int EnumFilters(out IntPtr enumFilters);
        [PreserveSig] int FindFilterByName([In, MarshalAs(UnmanagedType.LPWStr)] string name, out IBaseFilter filter);
        [PreserveSig] int ConnectDirect(IntPtr pinOut, IntPtr pinIn, [In] AMMediaType mt);
        [PreserveSig] int Reconnect(IntPtr pin);
        [PreserveSig] int Disconnect(IntPtr pin);
        [PreserveSig] int SetDefaultSyncSource();
        // IGraphBuilder
        [PreserveSig] int Connect(IntPtr pinOut, IntPtr pinIn);
        [PreserveSig] int Render(IntPtr pinOut);
        [PreserveSig] int RenderFile([In, MarshalAs(UnmanagedType.LPWStr)] string file, [In, MarshalAs(UnmanagedType.LPWStr)] string playList);
        [PreserveSig] int AddSourceFilter([In, MarshalAs(UnmanagedType.LPWStr)] string fileName, [In, MarshalAs(UnmanagedType.LPWStr)] string filterName, out IBaseFilter filter);
        [PreserveSig] int SetLogFile(IntPtr file);
        [PreserveSig] int Abort();
        [PreserveSig] int ShouldOperationContinue();
    }

    [ComImport, Guid("93E5A4E0-2D50-11d2-ABFA-00A0C9C6E38D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ICaptureGraphBuilder2
    {
        [PreserveSig] int SetFiltergraph([In] IGraphBuilder graph);
        [PreserveSig] int GetFiltergraph(out IGraphBuilder graph);
        [PreserveSig] int SetOutputFileName([In] ref Guid type, [In, MarshalAs(UnmanagedType.LPWStr)] string file, out IBaseFilter mux, out IntPtr sink);
        [PreserveSig] int FindInterface([In] ref Guid category, [In] ref Guid type, [In] IBaseFilter filter, [In] ref Guid iid, [Out, MarshalAs(UnmanagedType.IUnknown)] out object o);
        [PreserveSig] int RenderStream([In] ref Guid category, [In] ref Guid type, [In, MarshalAs(UnmanagedType.IUnknown)] object source, [In] IBaseFilter compressor, [In] IBaseFilter renderer);
        [PreserveSig] int ControlStream([In] ref Guid category, [In] ref Guid type, [In] IBaseFilter filter, IntPtr start, IntPtr stop, short startCookie, short stopCookie);
        [PreserveSig] int AllocCapFile([In, MarshalAs(UnmanagedType.LPWStr)] string file, long size);
        [PreserveSig] int CopyCaptureFile([In, MarshalAs(UnmanagedType.LPWStr)] string oldFile, [In, MarshalAs(UnmanagedType.LPWStr)] string newFile, int allowEscAbort, IntPtr callback);
        [PreserveSig] int FindPin([In, MarshalAs(UnmanagedType.IUnknown)] object source, int direction, [In] ref Guid category, [In] ref Guid type, [In, MarshalAs(UnmanagedType.Bool)] bool unconnected, int index, out IntPtr pin);
    }

    [ComImport, Guid("6B652FFF-11FE-4fce-92AD-0266B5D7C78F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface ISampleGrabber
    {
        [PreserveSig] int SetOneShot([In, MarshalAs(UnmanagedType.Bool)] bool oneShot);
        [PreserveSig] int SetMediaType([In] AMMediaType mt);
        [PreserveSig] int GetConnectedMediaType([Out] AMMediaType mt);
        [PreserveSig] int SetBufferSamples([In, MarshalAs(UnmanagedType.Bool)] bool bufferThem);
        [PreserveSig] int GetCurrentBuffer(ref int bufferSize, IntPtr buffer);
        [PreserveSig] int GetCurrentSample(out IntPtr sample);
        [PreserveSig] int SetCallback(IntPtr callback, int whichMethod);
    }

    [ComImport, Guid("C6E13340-30AC-11d0-A18C-00A0C9118956"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAMStreamConfig
    {
        [PreserveSig] int SetFormat([In] AMMediaType mt);
        [PreserveSig] int GetFormat(out IntPtr pmt);
        [PreserveSig] int GetNumberOfCapabilities(out int count, out int size);
        [PreserveSig] int GetStreamCaps(int index, out IntPtr pmt, IntPtr scc);
    }

    [ComImport, Guid("56a868b1-0ad4-11ce-b03a-0020af0ba770"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    interface IMediaControl
    {
        [PreserveSig] int Run();
        [PreserveSig] int Pause();
        [PreserveSig] int Stop();
        [PreserveSig] int GetState(int msTimeout, out int state);
        [PreserveSig] int RenderFile([In, MarshalAs(UnmanagedType.BStr)] string fileName);
        [PreserveSig] int AddSourceFilter([In, MarshalAs(UnmanagedType.BStr)] string fileName, [Out, MarshalAs(UnmanagedType.IDispatch)] out object filterInfo);
        [PreserveSig] int get_FilterCollection([Out, MarshalAs(UnmanagedType.IDispatch)] out object collection);
        [PreserveSig] int get_RegFilterCollection([Out, MarshalAs(UnmanagedType.IDispatch)] out object collection);
        [PreserveSig] int StopWhenReady();
    }

    #endregion
}
