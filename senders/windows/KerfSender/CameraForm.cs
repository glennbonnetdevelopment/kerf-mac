using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace KerfSender
{
    /// <summary>
    /// Camera registration for lasers: calibrate the lens, align the camera to the bed with a burned target,
    /// then move the job's outline onto the material in the picture. The main window runs the job where it's placed.
    /// </summary>
    public sealed class CameraForm : Form
    {
        readonly GrblConnection grbl;
        readonly Func<Job> currentJob;
        readonly Action<string, bool> log;
        readonly Func<bool> isLaser;

        // Camera
        readonly ComboBox cameraBox = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList, Width = 260 };
        readonly Button refreshButton = new Button { Text = "Refresh", AutoSize = true };
        readonly Button startButton = new Button { Text = "Start camera", AutoSize = true };
        readonly Label cameraStatus = new Label { AutoSize = true, ForeColor = SystemColors.GrayText, Padding = new Padding(0, 6, 0, 0) };
        readonly PicturePanel picture = new PicturePanel { Dock = DockStyle.Fill, BackColor = Color.FromArgb(40, 40, 40) };
        readonly TabControl tabs = new TabControl { Dock = DockStyle.Fill };
        readonly System.Windows.Forms.Timer frameTimer = new System.Windows.Forms.Timer { Interval = 80 };
        CameraCapture capture;
        List<CameraDevice> devices = new List<CameraDevice>();
        CameraDevice device;
        CameraSetup setup = new CameraSetup();
        CameraFrame frame;
        Bitmap bitmap;

        // Lens
        readonly NumericUpDown boardCols = Number(3, 30, 9, 0);
        readonly NumericUpDown boardRows = Number(3, 30, 6, 0);
        readonly Button captureBoardButton = new Button { Text = "Capture board", AutoSize = true };
        readonly Button calibrateButton = new Button { Text = "Calibrate lens", AutoSize = true };
        readonly Button clearViewsButton = new Button { Text = "Clear views", AutoSize = true };
        readonly Button forgetLensButton = new Button { Text = "Forget lens", AutoSize = true };
        readonly Label lensStatus = Note("");
        readonly List<CheckerboardView> boardViews = new List<CheckerboardView>();
        V2[] lastCorners;
        DateTime lastCornersTime;
        bool detecting;

        // Alignment
        readonly NumericUpDown markCols = Number(2, 5, 3, 0);
        readonly NumericUpDown markRows = Number(2, 5, 3, 0);
        readonly NumericUpDown margin = Number(0, 500, 40, 0);
        readonly NumericUpDown markSize = Number(4, 40, 12, 0);
        readonly NumericUpDown speed = Number(50, 20000, 1500, 0);
        readonly NumericUpDown power = Number(1, 100, 25, 0);
        readonly NumericUpDown sMax = Number(1, 100000, 1000, 0);
        readonly NumericUpDown bedW = Number(20, 3000, 400, 0);
        readonly NumericUpDown bedH = Number(20, 3000, 400, 0);
        readonly Button burnButton = new Button { Text = "Burn target…", AutoSize = true };
        readonly Button snapshotButton = new Button { Text = "Take snapshot", AutoSize = true };
        readonly Button liveButton = new Button { Text = "Back to live", AutoSize = true };
        readonly Button undoButton = new Button { Text = "Undo last", AutoSize = true };
        readonly Button clearClicksButton = new Button { Text = "Clear", AutoSize = true };
        readonly Button findRestButton = new Button { Text = "Find the rest", AutoSize = true };
        readonly Button saveAlignButton = new Button { Text = "Save alignment", AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont, FontStyle.Bold) };
        readonly Button forgetAlignButton = new Button { Text = "Forget alignment", AutoSize = true };
        readonly Label clickStatus = Note("");
        readonly Label fitStatus = Note("");
        CameraFrame snapshot;
        V2?[] clicks = new V2?[0];
        int pick;
        double burnWcoX, burnWcoY;
        bool haveBurnWco;

        // Placement
        readonly NumericUpDown moveX = Number(-5000, 5000, 0, 1);
        readonly NumericUpDown moveY = Number(-5000, 5000, 0, 1);
        readonly NumericUpDown turn = Number(-360, 360, 0, 1);
        readonly CheckBox useCheck = new CheckBox { Text = "Run the job where it's placed", AutoSize = true };
        readonly Button resetButton = new Button { Text = "Reset", AutoSize = true };
        readonly Label placeStatus = Note("");
        Job toolpathJob;
        GcodeToolpath toolpath;
        bool updatingPlacement;
        V2? dragFrom;

        public CameraForm(GrblConnection grbl, Func<Job> currentJob, Func<bool> isLaser, Action<string, bool> log)
        {
            this.grbl = grbl;
            this.currentJob = currentJob;
            this.isLaser = isLaser;
            this.log = log;
            Text = "Camera — KerfSender";
            Font = SystemFonts.MessageBoxFont;
            AutoScaleMode = AutoScaleMode.Font;
            ClientSize = new Size(1080, 680);
            MinimumSize = new Size(860, 560);
            StartPosition = FormStartPosition.CenterParent;
            ShowInTaskbar = false;
            turn.Increment = 1;
            moveX.Increment = moveY.Increment = 1;
            LoadTarget();
            BuildLayout();
            WireEvents();
            RefreshDevices();
            UpdateAll();
        }

        static NumericUpDown Number(decimal min, decimal max, decimal value, int decimals)
        {
            return new NumericUpDown { Minimum = min, Maximum = max, Value = value, DecimalPlaces = decimals, Width = 80, TextAlign = HorizontalAlignment.Right };
        }

        static Label Note(string text)
        {
            return new Label { Text = text, AutoSize = true, MaximumSize = new Size(330, 0), ForeColor = SystemColors.GrayText, Margin = new Padding(3, 3, 3, 6) };
        }

        #region Layout

        void BuildLayout()
        {
            var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, Padding = new Padding(8) };
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 370));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

            var top = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Dock = DockStyle.Fill };
            top.Controls.Add(new Label { Text = "Camera:", AutoSize = true, Padding = new Padding(0, 6, 0, 0) });
            top.Controls.Add(cameraBox);
            top.Controls.Add(refreshButton);
            top.Controls.Add(startButton);
            top.Controls.Add(cameraStatus);
            root.Controls.Add(top, 0, 0);
            root.SetColumnSpan(top, 2);
            root.Controls.Add(picture, 0, 1);

            tabs.TabPages.Add(Page("1. Lens", LensControls()));
            tabs.TabPages.Add(Page("2. Alignment", AlignmentControls()));
            tabs.TabPages.Add(Page("3. Place job", PlaceControls()));
            root.Controls.Add(tabs, 1, 1);
            Controls.Add(root);
        }

        static TabPage Page(string title, Control[] controls)
        {
            var page = new TabPage(title);
            var flow = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(6) };
            flow.Controls.AddRange(controls);
            page.Controls.Add(flow);
            return page;
        }

        static Control Row(params Control[] items)
        {
            var r = new FlowLayoutPanel { AutoSize = true, WrapContents = false, Margin = new Padding(0) };
            r.Controls.AddRange(items);
            return r;
        }

        static Control Field(string title, NumericUpDown box, string unit)
        {
            return Row(new Label { Text = title, Width = 150, Padding = new Padding(0, 4, 0, 0) }, box,
                       new Label { Text = unit, AutoSize = true, ForeColor = SystemColors.GrayText, Padding = new Padding(0, 4, 0, 0) });
        }

        static Label Heading(string text)
        {
            return new Label { Text = text, AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont, FontStyle.Bold), Margin = new Padding(3, 10, 3, 3) };
        }

        Control[] LensControls()
        {
            return new Control[]
            {
                Note("Optional, but it makes the picture line up much better near the edges. Print a checkerboard (any size of squares), hold or lay it flat under the camera and capture it in 8 to 15 places: middle, every edge and every corner, some of them tilted."),
                Field("Inner corners across", boardCols, ""),
                Field("Inner corners down", boardRows, ""),
                Note("Count where four squares meet: a board of 10 × 7 squares has 9 × 6."),
                Row(captureBoardButton, clearViewsButton),
                Row(calibrateButton, forgetLensButton),
                lensStatus,
            };
        }

        Control[] AlignmentControls()
        {
            return new Control[]
            {
                Note("Burn marks at known places on the bed, then click them in a snapshot. Do it again if the camera or its mount moves. Calibrate the lens first if you're going to."),
                Heading("Burn the target"),
                Note("Home the laser, then cover the bed with scrap card or plywood the camera can see, at the height you usually work."),
                Field("Marks across", markCols, ""),
                Field("Marks down", markRows, ""),
                Field("Bed width", bedW, "mm"),
                Field("Bed height", bedH, "mm"),
                Field("Edge margin", margin, "mm"),
                Field("Mark size", markSize, "mm"),
                Field("Speed", speed, "mm/min"),
                Field("Power", power, "%"),
                Field("Full power S value", sMax, "($30)"),
                burnButton,
                Heading("Click the marks"),
                Row(snapshotButton, liveButton),
                Note("Mark 1 has a small inner ring and is the one nearest X 0, Y 0; mark 2 is next to it along X. Clicks snap to the mark's centre; hold Shift to place one exactly. After three marks, Find the rest finds the others."),
                clickStatus,
                Row(undoButton, clearClicksButton, findRestButton),
                Heading("Save"),
                fitStatus,
                Row(saveAlignButton, forgetAlignButton),
            };
        }

        Control[] PlaceControls()
        {
            return new Control[]
            {
                Note("The job's outline is drawn on the picture where it will burn. Drag it onto the material, or type a move and a turn."),
                Field("Move X", moveX, "mm"),
                Field("Move Y", moveY, "mm"),
                Field("Turn", turn, "°"),
                Row(resetButton),
                useCheck,
                placeStatus,
                Note("The red cross is the laser head, from the machine's position reports, so you can check the alignment: jog the head and it should follow."),
            };
        }

        #endregion

        void WireEvents()
        {
            refreshButton.Click += (s, e) => RefreshDevices();
            cameraBox.SelectedIndexChanged += (s, e) =>
            {
                var d = cameraBox.SelectedItem as CameraDevice;
                if (d == device) return;
                bool wasRunning = capture != null && capture.IsRunning;
                StopCamera();
                device = d;
                setup = device == null ? new CameraSetup() : CameraStore.Load(device.Id);
                boardViews.Clear();
                lensStatus.Text = "";
                snapshot = null;
                ClearClicks();
                if (wasRunning) StartCamera();
                UpdateAll();
            };
            startButton.Click += (s, e) => { if (capture != null && capture.IsRunning) StopCamera(); else StartCamera(); UpdateAll(); };
            frameTimer.Tick += (s, e) => GrabFrame();

            captureBoardButton.Click += (s, e) => CaptureBoard();
            clearViewsButton.Click += (s, e) => { boardViews.Clear(); lastCorners = null; UpdateAll(); };
            calibrateButton.Click += (s, e) => CalibrateLens();
            forgetLensButton.Click += (s, e) => { setup.Lens = null; SaveSetup(); lensStatus.Text = "Lens forgotten."; UpdateAll(); };

            foreach (var n in new[] { markCols, markRows, margin, bedW, bedH })
                n.ValueChanged += (s, e) => { ClearClicks(); UpdateAll(); };
            burnButton.Click += (s, e) => BurnTarget();
            snapshotButton.Click += (s, e) =>
            {
                if (frame == null) return;
                snapshot = frame;
                ClearClicks();
                UpdateAll();
            };
            liveButton.Click += (s, e) => { snapshot = null; ClearClicks(); UpdateAll(); };
            undoButton.Click += (s, e) => UndoClick();
            clearClicksButton.Click += (s, e) => { ClearClicks(); UpdateAll(); };
            findRestButton.Click += (s, e) => FindRest();
            saveAlignButton.Click += (s, e) => SaveAlignment();
            forgetAlignButton.Click += (s, e) => { setup.Alignment = null; SaveSetup(); UpdateAll(); };

            foreach (var n in new[] { moveX, moveY, turn })
                n.ValueChanged += (s, e) => { if (!updatingPlacement) useCheck.Checked = Placed; UpdateAll(); };
            resetButton.Click += (s, e) => { SetPlacement(0, 0, 0); useCheck.Checked = false; UpdateAll(); };
            useCheck.CheckedChanged += (s, e) => UpdateAll();
            tabs.SelectedIndexChanged += (s, e) => UpdateAll();

            picture.Paint += PaintPicture;
            picture.MouseDown += PictureMouseDown;
            picture.MouseMove += PictureMouseMove;
            picture.MouseUp += (s, e) => { dragFrom = null; };

            FormClosing += (s, e) =>
            {
                // Hide instead of closing, so the placement stays for the main window.
                if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; StopCamera(); Hide(); }
                SaveTarget();
            };
        }

        #region Camera

        void RefreshDevices()
        {
            string current = device != null ? device.Id : CameraStore.LastCamera();
            devices = CameraCapture.Devices();
            cameraBox.Items.Clear();
            foreach (var d in devices) cameraBox.Items.Add(d);
            CameraDevice pickDevice = devices.Find(d => d.Id == current) ?? (devices.Count > 0 ? devices[0] : null);
            device = null;
            if (pickDevice != null) cameraBox.SelectedItem = pickDevice;
            else { setup = new CameraSetup(); UpdateAll(); }
        }

        void StartCamera()
        {
            if (device == null) return;
            try
            {
                capture = new CameraCapture();
                capture.Start(device, 1920, 1080);
                CameraStore.SetLastCamera(device.Id);
                frameTimer.Start();
                cameraStatus.Text = "Starting…";
            }
            catch (Exception ex)
            {
                if (capture != null) capture.Dispose();
                capture = null;
                cameraStatus.Text = "";
                MessageBox.Show(this, "The camera couldn't start.\n\n" + ex.Message, "KerfSender", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        void StopCamera()
        {
            frameTimer.Stop();
            if (capture != null) capture.Dispose();
            capture = null;
            cameraStatus.Text = "";
        }

        void GrabFrame()
        {
            if (capture == null) return;
            CameraFrame f;
            try { f = capture.Grab(); }
            catch (Exception) { f = null; }
            if (f == null) return;
            frame = f;
            cameraStatus.Text = f.Width + " × " + f.Height;
            if (snapshot == null) ShowFrame(f);
            UpdatePlaceStatus();
        }

        void ShowFrame(CameraFrame f)
        {
            if (bitmap == null || bitmap.Width != f.Width || bitmap.Height != f.Height)
            {
                if (bitmap != null) bitmap.Dispose();
                bitmap = new Bitmap(f.Width, f.Height, PixelFormat.Format24bppRgb);
            }
            var data = bitmap.LockBits(new Rectangle(0, 0, f.Width, f.Height), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
            try
            {
                int row = f.Width * 3;
                for (int y = 0; y < f.Height; y++)
                    Marshal.Copy(f.Bgr, y * row, new IntPtr(data.Scan0.ToInt64() + (long)y * data.Stride), row);
            }
            finally { bitmap.UnlockBits(data); }
            picture.Invalidate();
        }

        /// <summary>The picture on screen: the frozen snapshot while clicking marks, else the latest frame.</summary>
        CameraFrame ShownFrame { get { return snapshot ?? frame; } }

        #endregion

        #region Lens

        void CaptureBoard()
        {
            var f = frame;
            if (f == null || detecting) return;
            if (boardViews.Count > 0 && (boardViews[0].ImageWidth != f.Width || boardViews[0].ImageHeight != f.Height)) boardViews.Clear();
            int cols = (int)boardCols.Value, rows = (int)boardRows.Value;
            detecting = true;
            lensStatus.Text = "Looking for the board…";
            UpdateAll();
            ThreadPool.QueueUserWorkItem(_ =>
            {
                CheckerboardView v = null;
                try { v = CheckerboardDetector.Detect(f.Gray, cols, rows); }
                catch (Exception) { }
                BeginInvoke((Action)(() =>
                {
                    detecting = false;
                    if (v == null)
                    {
                        lensStatus.Text = "The board wasn't found. Check the corner counts, and that the whole board is in the picture, evenly lit and in focus.";
                    }
                    else
                    {
                        boardViews.Add(v);
                        lastCorners = v.ImagePoints;
                        lastCornersTime = DateTime.Now;
                        lensStatus.Text = "Board found (" + boardViews.Count + " view" + (boardViews.Count == 1 ? "" : "s") + "). Move it somewhere else and capture again.";
                    }
                    UpdateAll();
                    picture.Invalidate();
                }));
            });
        }

        void CalibrateLens()
        {
            var views = new List<CheckerboardView>(boardViews);
            if (views.Count < LensCalibration.MinimumViews) return;
            Cursor = Cursors.WaitCursor;
            LensModel lens = null;
            try { lens = LensCalibration.Calibrate(views); }
            catch (Exception) { }
            finally { Cursor = Cursors.Default; }
            if (lens == null)
            {
                lensStatus.Text = "Calibration failed. Clear the views and capture the board again in more places.";
                return;
            }
            setup.Lens = lens;
            // An alignment made through the old lens no longer fits.
            if (setup.Alignment != null)
            {
                setup.Alignment = null;
                lensStatus.Text = "The alignment was cleared because the lens changed; align again.\n";
            }
            else lensStatus.Text = "";
            lensStatus.Text += string.Format(CultureInfo.CurrentCulture, "Lens calibrated from {0} views: corners fit within {1:0.00} px. Distortion at the corners {2:0.0}%.",
                lens.Views, lens.RmsError, lens.CornerDistortion * 100);
            if (lens.RmsError > 1.0) lensStatus.Text += " That's a loose fit: capture more views, keeping the board still and flat.";
            SaveSetup();
            UpdateAll();
        }

        #endregion

        #region Alignment

        List<V2> MarksWork()
        {
            double m = Math.Max(0, Math.Min((double)margin.Value, Math.Min((double)bedW.Value, (double)bedH.Value) / 2 - 5));
            return CameraTarget.MarkCentres(m, m, (double)bedW.Value - m, (double)bedH.Value - m, (int)markCols.Value, (int)markRows.Value);
        }

        /// <summary>The marks in machine coordinates: where they were burned plus the work offset at the time.</summary>
        List<V2> MarksMachine()
        {
            var o = new List<V2>();
            double wx = haveBurnWco ? burnWcoX : grbl.WorkOffset[0], wy = haveBurnWco ? burnWcoY : grbl.WorkOffset[1];
            foreach (var m in MarksWork()) o.Add(new V2(m.X + wx, m.Y + wy));
            return o;
        }

        void BurnTarget()
        {
            var marks = MarksWork();
            double minX = double.MaxValue, maxX = double.MinValue, minY = double.MaxValue, maxY = double.MinValue;
            foreach (var m in marks) { minX = Math.Min(minX, m.X); maxX = Math.Max(maxX, m.X); minY = Math.Min(minY, m.Y); maxY = Math.Max(maxY, m.Y); }
            string msg = string.Format(CultureInfo.CurrentCulture,
                "The laser will burn {0} marks between X {1:0}–{2:0} and Y {3:0}–{4:0} mm (work coordinates, so set the origin at machine home first, or home the machine), at {5:0}% power.\n\nStay with the machine. Burn the target?",
                marks.Count, minX, maxX, minY, maxY, power.Value);
            if (MessageBox.Show(this, msg, "Burn the alignment target", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK) return;
            burnWcoX = grbl.WorkOffset[0];
            burnWcoY = grbl.WorkOffset[1];
            haveBurnWco = true;
            SaveTarget();
            ClearClicks();
            grbl.Run(CameraTarget.GCode(marks, (double)markSize.Value, (double)speed.Value, (double)power.Value, (double)sMax.Value));
            UpdateAll();
        }

        void ClearClicks()
        {
            clicks = new V2?[(int)markCols.Value * (int)markRows.Value];
            pick = 0;
        }

        void UndoClick()
        {
            int last = -1;
            for (int i = Math.Min(pick, clicks.Length) - 1; i >= 0; i--) if (clicks[i].HasValue) { last = i; break; }
            if (last < 0) for (int i = clicks.Length - 1; i >= 0; i--) if (clicks[i].HasValue) { last = i; break; }
            if (last < 0) return;
            clicks[last] = null;
            pick = last;
            UpdateAll();
        }

        double SnapRadius(CameraFrame f)
        {
            var marks = MarksWork();
            var known = new List<int>();
            for (int i = 0; i < clicks.Length; i++) if (clicks[i].HasValue) known.Add(i);
            if (known.Count >= 2)
            {
                double mm = marks[known[0]].Dist(marks[known[1]]);
                if (mm > 1) return Math.Max(6, clicks[known[0]].Value.Dist(clicks[known[1]].Value) / mm * (double)markSize.Value * 0.75);
            }
            return f.Width * 0.03;
        }

        void ClickMark(V2 q, bool snap)
        {
            var f = snapshot;
            if (f == null || pick >= clicks.Length) return;
            V2 p = q;
            if (snap)
            {
                V2 s;
                if (CameraTarget.SnapToMark(f.Gray, q, SnapRadius(f), out s)) p = s;
            }
            clicks[pick] = p;
            pick = Array.FindIndex(clicks, c => !c.HasValue);
            if (pick < 0) pick = clicks.Length;
            UpdateAll();
        }

        void FindRest()
        {
            var f = snapshot;
            if (f == null) return;
            var guess = CameraTarget.Predict(MarksWork(), clicks);
            double radius = SnapRadius(f);
            int found = 0, missed = 0;
            for (int i = 0; i < clicks.Length; i++)
            {
                if (clicks[i].HasValue || !guess[i].HasValue) continue;
                V2 s;
                if (CameraTarget.SnapToMark(f.Gray, guess[i].Value, radius * 1.5, out s)) { clicks[i] = s; found++; }
                else missed++;
            }
            pick = Array.FindIndex(clicks, c => !c.HasValue);
            if (pick < 0) pick = clicks.Length;
            if (missed > 0) log("Camera: " + missed + " mark(s) weren't found; click them yourself.", false);
            UpdateAll();
        }

        Homography AlignmentFit(out double rms, out double max)
        {
            rms = max = 0;
            var f = snapshot;
            if (f == null) return null;
            var marks = MarksMachine();
            var lens = setup.LensAt(f.Width, f.Height);
            var img = new List<V2>();
            var bed = new List<V2>();
            for (int i = 0; i < clicks.Length && i < marks.Count; i++)
            {
                if (!clicks[i].HasValue) continue;
                img.Add(lens != null ? lens.UndistortPixel(clicks[i].Value) : clicks[i].Value);
                bed.Add(marks[i]);
            }
            return CameraTarget.Fit(img, bed, out rms, out max);
        }

        void SaveAlignment()
        {
            var f = snapshot;
            double rms, max;
            var h = AlignmentFit(out rms, out max);
            if (f == null || h == null) return;
            if (setup.Lens != null && setup.LensAt(f.Width, f.Height) == null)
            {
                MessageBox.Show(this, "The camera's picture size changed since the lens was calibrated. Calibrate the lens again.", "KerfSender");
                return;
            }
            setup.Alignment = new BedAlignment { ImageWidth = f.Width, ImageHeight = f.Height, ImageToBed = h, RmsError = rms, MaxError = max, Date = DateTime.UtcNow };
            SaveSetup();
            snapshot = null;
            ClearClicks();
            log(string.Format(CultureInfo.CurrentCulture, "Camera aligned: marks within {0:0.00} mm on average (worst {1:0.00} mm).", rms, max), false);
            tabs.SelectedIndex = 2;
            UpdateAll();
        }

        #endregion

        #region Placement

        bool Placed { get { return moveX.Value != 0 || moveY.Value != 0 || turn.Value != 0; } }

        void SetPlacement(double dx, double dy, double deg)
        {
            updatingPlacement = true;
            moveX.Value = Clamp(moveX, (decimal)Math.Round(dx, 1));
            moveY.Value = Clamp(moveY, (decimal)Math.Round(dy, 1));
            turn.Value = Clamp(turn, (decimal)Math.Round(deg, 1));
            updatingPlacement = false;
        }

        static decimal Clamp(NumericUpDown n, decimal v) { return Math.Max(n.Minimum, Math.Min(n.Maximum, v)); }

        GcodeToolpath Toolpath()
        {
            var job = currentJob();
            if (job == null || !job.UsesGrbl) { toolpath = null; toolpathJob = null; return null; }
            if (job != toolpathJob)
            {
                toolpathJob = job;
                toolpath = GcodeToolpath.Read(job.GcodeLines());
                SetPlacement(0, 0, 0);
                useCheck.Checked = false;
            }
            return toolpath;
        }

        /// <summary>True when the main window should run the placed copy of the job.</summary>
        public bool PlacementActive { get { return useCheck.Checked && Placed && Toolpath() != null && !Toolpath().IsEmpty; } }

        public string PlacementDescription
        {
            get { return string.Format(CultureInfo.CurrentCulture, "moved X {0:0.#} mm, Y {1:0.#} mm, turned {2:0.#}°", moveX.Value, moveY.Value, turn.Value); }
        }

        /// <summary>The job's G-code moved and turned as placed, or null with an error.</summary>
        public List<string> PlacedLines(Job job, out string error)
        {
            error = null;
            var tp = Toolpath();
            if (tp == null || tp.IsEmpty) { error = "The job has no moves to place."; return null; }
            return GcodeToolpath.Transform(job.GcodeLines(), tp.Centre, (double)turn.Value, new V2((double)moveX.Value, (double)moveY.Value), out error);
        }

        V2 PlaceWork(V2 p, V2 centre, double ca, double sa)
        {
            V2 d = p - centre;
            return new V2(centre.X + d.X * ca - d.Y * sa + (double)moveX.Value, centre.Y + d.X * sa + d.Y * ca + (double)moveY.Value);
        }

        void UpdatePlaceStatus()
        {
            if (tabs.SelectedIndex != 2) return;
            var tp = Toolpath();
            string s;
            if (setup.Alignment == null) s = "Align the camera first (step 2).";
            else if (currentJob() == null) s = "Open a job in the main window.";
            else if (tp == null) s = "This job isn't G-code, so it can't be placed with the camera.";
            else if (tp.IsEmpty) s = "The job has no burning moves to show.";
            else if (tp.HasRelativeMoves) s = "The job uses relative moves (G91), so it can't be moved here.";
            else
            {
                s = string.Format(CultureInfo.CurrentCulture, "Job: {0:0.#} × {1:0.#} mm.", tp.MaxX - tp.MinX, tp.MaxY - tp.MinY);
                if (!grbl.IsConnected) s += " Connect the machine so the outline uses its current origin.";
                else if (!grbl.HasWorkOffset) s += " Waiting for the machine to report its origin…";
                if (useCheck.Checked && Placed) s += " Start in the main window runs it as placed.";
            }
            if (placeStatus.Text != s) placeStatus.Text = s;
        }

        #endregion

        #region Drawing and mouse

        sealed class Fit
        {
            public float Scale, OffX, OffY;
            public PointF ToView(V2 p) { return new PointF((float)(OffX + (p.X + 0.5) * Scale), (float)(OffY + (p.Y + 0.5) * Scale)); }
            public V2 ToImage(Point v) { return new V2((v.X - OffX) / Scale - 0.5, (v.Y - OffY) / Scale - 0.5); }
        }

        Fit CurrentFit()
        {
            var f = ShownFrame;
            if (f == null) return null;
            float s = Math.Min((float)picture.ClientSize.Width / f.Width, (float)picture.ClientSize.Height / f.Height);
            if (s <= 0) return null;
            return new Fit { Scale = s, OffX = (picture.ClientSize.Width - f.Width * s) / 2, OffY = (picture.ClientSize.Height - f.Height * s) / 2 };
        }

        void PaintPicture(object sender, PaintEventArgs e)
        {
            var g = e.Graphics;
            var f = ShownFrame;
            var fit = CurrentFit();
            if (f == null || fit == null || bitmap == null)
            {
                string t = devices.Count == 0 ? "No camera found. Plug in the USB camera and press Refresh." : "Press Start camera.";
                TextRenderer.DrawText(g, t, Font, picture.ClientRectangle, Color.Gainsboro, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.WordBreak);
                return;
            }
            g.InterpolationMode = InterpolationMode.Bilinear;
            g.DrawImage(bitmap, fit.OffX, fit.OffY, f.Width * fit.Scale, f.Height * fit.Scale);
            g.SmoothingMode = SmoothingMode.AntiAlias;

            int tab = tabs.SelectedIndex;
            if (tab == 0 && lastCorners != null && (DateTime.Now - lastCornersTime).TotalSeconds < 4)
            {
                using (var pen = new Pen(Color.Lime, 2))
                    foreach (var c in lastCorners) { var v = fit.ToView(c); g.DrawEllipse(pen, v.X - 4, v.Y - 4, 8, 8); }
            }
            if (tab == 1 && snapshot != null) DrawClicks(g, fit);
            if (tab == 2) DrawJob(g, fit, f);
            if (setup.Alignment != null && tab != 1) DrawHead(g, fit, f);
        }

        void DrawClicks(Graphics g, Fit fit)
        {
            using (var pen = new Pen(Color.Orange, 2))
            using (var font = new Font(Font.FontFamily, 9, FontStyle.Bold))
            {
                for (int i = 0; i < clicks.Length; i++)
                {
                    if (!clicks[i].HasValue) continue;
                    var v = fit.ToView(clicks[i].Value);
                    g.DrawLine(pen, v.X - 8, v.Y, v.X + 8, v.Y);
                    g.DrawLine(pen, v.X, v.Y - 8, v.X, v.Y + 8);
                    g.DrawString((i + 1).ToString(CultureInfo.InvariantCulture), font, Brushes.Orange, v.X + 6, v.Y + 4);
                }
            }
        }

        void DrawHead(Graphics g, Fit fit, CameraFrame f)
        {
            var mp = grbl.MachinePosition;
            if (mp == null) return;
            V2 q;
            if (!setup.BedToImage(new V2(mp[0], mp[1]), f.Width, f.Height, out q)) return;
            var v = fit.ToView(q);
            using (var pen = new Pen(Color.Red, 2))
            {
                g.DrawEllipse(pen, v.X - 7, v.Y - 7, 14, 14);
                g.DrawLine(pen, v.X - 12, v.Y, v.X + 12, v.Y);
                g.DrawLine(pen, v.X, v.Y - 12, v.X, v.Y + 12);
            }
        }

        void DrawJob(Graphics g, Fit fit, CameraFrame f)
        {
            var tp = Toolpath();
            if (tp == null || tp.IsEmpty || setup.Alignment == null) return;
            V2 c = tp.Centre;
            double a = (double)turn.Value * Math.PI / 180, ca = Math.Cos(a), sa = Math.Sin(a);
            double wx = grbl.WorkOffset[0], wy = grbl.WorkOffset[1];
            bool curved = setup.Lens != null;
            Func<V2, PointF?> view = p =>
            {
                var w = PlaceWork(p, c, ca, sa);
                V2 q;
                if (!setup.BedToImage(new V2(w.X + wx, w.Y + wy), f.Width, f.Height, out q)) return null;
                return fit.ToView(q);
            };
            using (var pen = new Pen(Color.FromArgb(230, 0, 200, 255), 1.5f))
            using (var box = new Pen(Color.FromArgb(200, 255, 220, 0), 1) { DashStyle = DashStyle.Dash })
            {
                var outline = new List<V2> { new V2(tp.MinX, tp.MinY), new V2(tp.MaxX, tp.MinY), new V2(tp.MaxX, tp.MaxY), new V2(tp.MinX, tp.MaxY), new V2(tp.MinX, tp.MinY) };
                DrawPolyline(g, box, outline, view, true);
                if (tp.PointCount <= 150000)
                    foreach (var b in tp.Burns) DrawPolyline(g, pen, b, view, curved);
            }
        }

        static void DrawPolyline(Graphics g, Pen pen, List<V2> pts, Func<V2, PointF?> view, bool densify)
        {
            var run = new List<PointF>();
            Action flush = () =>
            {
                if (run.Count >= 2) g.DrawLines(pen, run.ToArray());
                run.Clear();
            };
            for (int i = 0; i < pts.Count; i++)
            {
                if (densify && i > 0)
                {
                    double len = pts[i].Dist(pts[i - 1]);
                    int steps = Math.Min(200, (int)(len / 4));
                    for (int k = 1; k < steps; k++)
                    {
                        var v = view(pts[i - 1] + (pts[i] - pts[i - 1]) * ((double)k / steps));
                        if (v.HasValue) run.Add(v.Value); else flush();
                    }
                }
                var p = view(pts[i]);
                if (p.HasValue) run.Add(p.Value); else flush();
            }
            flush();
        }

        bool PictureToBed(Point pt, out V2 bed)
        {
            bed = new V2();
            var f = ShownFrame;
            var fit = CurrentFit();
            if (f == null || fit == null) return false;
            return setup.ImageToBed(fit.ToImage(pt), f.Width, f.Height, out bed);
        }

        void PictureMouseDown(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            var fit = CurrentFit();
            if (fit == null) return;
            if (tabs.SelectedIndex == 1 && snapshot != null)
            {
                var q = fit.ToImage(e.Location);
                if (q.X < 0 || q.Y < 0 || q.X >= snapshot.Width || q.Y >= snapshot.Height) return;
                ClickMark(q, (ModifierKeys & Keys.Shift) == 0);
                picture.Invalidate();
            }
            else if (tabs.SelectedIndex == 2 && setup.Alignment != null && Toolpath() != null)
            {
                V2 b;
                if (PictureToBed(e.Location, out b)) dragFrom = b;
            }
        }

        void PictureMouseMove(object sender, MouseEventArgs e)
        {
            if (!dragFrom.HasValue || e.Button != MouseButtons.Left) return;
            V2 b;
            if (!PictureToBed(e.Location, out b)) return;
            V2 d = b - dragFrom.Value;
            dragFrom = b;
            SetPlacement((double)moveX.Value + d.X, (double)moveY.Value + d.Y, (double)turn.Value);
            useCheck.Checked = Placed;
            UpdateAll();
        }

        #endregion

        void UpdateAll()
        {
            bool running = capture != null && capture.IsRunning;
            startButton.Text = running ? "Stop camera" : "Start camera";
            startButton.Enabled = device != null;
            cameraBox.Enabled = true;

            captureBoardButton.Enabled = running && frame != null && !detecting;
            calibrateButton.Enabled = boardViews.Count >= LensCalibration.MinimumViews;
            clearViewsButton.Enabled = boardViews.Count > 0;
            forgetLensButton.Enabled = setup.Lens != null;
            if (lensStatus.Text.Length == 0)
                lensStatus.Text = setup.Lens != null
                    ? string.Format(CultureInfo.CurrentCulture, "Lens calibrated ({0} views, {1:0.00} px).", setup.Lens.Views, setup.Lens.RmsError)
                    : "Not calibrated.";
            calibrateButton.Text = boardViews.Count > 0 ? "Calibrate lens (" + boardViews.Count + " views)" : "Calibrate lens";

            bool laser = isLaser();
            burnButton.Enabled = laser && grbl.IsConnected && !grbl.IsRunning;
            snapshotButton.Text = snapshot == null ? "Take snapshot" : "Retake snapshot";
            snapshotButton.Enabled = running && frame != null;
            liveButton.Enabled = snapshot != null;
            int clicked = 0;
            foreach (var c in clicks) if (c.HasValue) clicked++;
            undoButton.Enabled = clearClicksButton.Enabled = clicked > 0;
            findRestButton.Enabled = snapshot != null && clicked >= 3 && clicked < clicks.Length;
            if (snapshot == null) clickStatus.Text = laser ? "Take a snapshot once the target is burned." : "Pick GRBL laser as the machine type in the main window to burn the target.";
            else if (pick < clicks.Length)
            {
                var m = MarksWork()[pick];
                clickStatus.Text = string.Format(CultureInfo.CurrentCulture, "Click mark {0} of {1} (X {2:0}, Y {3:0}).", pick + 1, clicks.Length, m.X, m.Y);
            }
            else clickStatus.Text = "All marks clicked.";
            double rms, max;
            var h = AlignmentFit(out rms, out max);
            saveAlignButton.Enabled = h != null;
            if (h != null)
            {
                fitStatus.Text = string.Format(CultureInfo.CurrentCulture, "The marks fit within {0:0.00} mm on average (worst {1:0.00} mm).", rms, max);
                if (max > 1.5) fitStatus.Text += " A big error usually means a mark was clicked out of order, or the lens needs calibrating.";
                fitStatus.ForeColor = max > 1.5 ? Color.DarkOrange : SystemColors.GrayText;
            }
            else
            {
                fitStatus.ForeColor = SystemColors.GrayText;
                fitStatus.Text = setup.Alignment != null
                    ? string.Format(CultureInfo.CurrentCulture, "Aligned {0:g} (marks within {1:0.00} mm). Click at least 4 marks to align again.", setup.Alignment.Date.ToLocalTime(), setup.Alignment.RmsError)
                    : "Not aligned. Click at least 4 marks.";
            }
            forgetAlignButton.Enabled = setup.Alignment != null;

            var tp = Toolpath();
            bool canPlace = setup.Alignment != null && tp != null && !tp.IsEmpty && !tp.HasRelativeMoves;
            moveX.Enabled = moveY.Enabled = turn.Enabled = resetButton.Enabled = useCheck.Enabled = canPlace;
            UpdatePlaceStatus();
            picture.Invalidate();
        }

        void SaveSetup()
        {
            if (device != null) CameraStore.Save(device.Id, setup);
        }

        void LoadTarget()
        {
            var t = CameraStore.LoadTarget();
            Action<NumericUpDown, string> set = (n, key) =>
            {
                double v;
                if (t.ContainsKey(key) && double.TryParse(t[key], NumberStyles.Float, CultureInfo.InvariantCulture, out v)) n.Value = Clamp(n, (decimal)v);
            };
            set(markCols, "columns"); set(markRows, "rows"); set(margin, "margin"); set(markSize, "markSize");
            set(speed, "speed"); set(power, "power"); set(sMax, "sMax"); set(bedW, "bedWidth"); set(bedH, "bedHeight");
            double x, y;
            if (t.ContainsKey("burnWcoX") && t.ContainsKey("burnWcoY") &&
                double.TryParse(t["burnWcoX"], NumberStyles.Float, CultureInfo.InvariantCulture, out x) &&
                double.TryParse(t["burnWcoY"], NumberStyles.Float, CultureInfo.InvariantCulture, out y))
            {
                burnWcoX = x; burnWcoY = y; haveBurnWco = true;
            }
            ClearClicks();
        }

        void SaveTarget()
        {
            var t = new Dictionary<string, string>();
            Action<string, decimal> put = (k, v) => t[k] = v.ToString(CultureInfo.InvariantCulture);
            put("columns", markCols.Value); put("rows", markRows.Value); put("margin", margin.Value); put("markSize", markSize.Value);
            put("speed", speed.Value); put("power", power.Value); put("sMax", sMax.Value); put("bedWidth", bedW.Value); put("bedHeight", bedH.Value);
            if (haveBurnWco)
            {
                t["burnWcoX"] = burnWcoX.ToString("R", CultureInfo.InvariantCulture);
                t["burnWcoY"] = burnWcoY.ToString("R", CultureInfo.InvariantCulture);
            }
            CameraStore.SaveTarget(t);
        }

        /// <summary>Fills the bed size from a newly opened job, when it says.</summary>
        public void JobOpened(Job job)
        {
            if (job != null && job.BedWidth > 0 && job.BedHeight > 0)
            {
                bedW.Value = Clamp(bedW, (decimal)job.BedWidth);
                bedH.Value = Clamp(bedH, (decimal)job.BedHeight);
            }
            UpdateAll();
        }

        public void MachineChanged()
        {
            if (Visible) UpdateAll();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                StopCamera();
                frameTimer.Dispose();
                if (bitmap != null) bitmap.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    /// <summary>A flicker-free panel for the camera picture.</summary>
    sealed class PicturePanel : Panel
    {
        public PicturePanel()
        {
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
            Cursor = Cursors.Cross;
        }
    }

    /// <summary>Camera calibrations and target settings in %APPDATA%\KerfSender\camera\.</summary>
    static class CameraStore
    {
        static string Folder
        {
            get { return Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "KerfSender"), "camera"); }
        }

        static string FileFor(string id)
        {
            using (var md5 = MD5.Create())
            {
                var hash = md5.ComputeHash(Encoding.UTF8.GetBytes(id ?? ""));
                var sb = new StringBuilder();
                for (int i = 0; i < 8; i++) sb.Append(hash[i].ToString("x2"));
                return Path.Combine(Folder, sb + ".txt");
            }
        }

        public static CameraSetup Load(string id)
        {
            try { return File.Exists(FileFor(id)) ? CameraSetup.Parse(File.ReadAllText(FileFor(id))) : new CameraSetup(); }
            catch (Exception) { return new CameraSetup(); }
        }

        public static void Save(string id, CameraSetup s)
        {
            try
            {
                Directory.CreateDirectory(Folder);
                File.WriteAllText(FileFor(id), "camera=" + id.Replace('\n', ' ') + "\n" + s.Serialize());
            }
            catch (Exception) { }
        }

        public static string LastCamera()
        {
            try { var p = Path.Combine(Folder, "last.txt"); return File.Exists(p) ? File.ReadAllText(p).Trim() : null; }
            catch (Exception) { return null; }
        }

        public static void SetLastCamera(string id)
        {
            try { Directory.CreateDirectory(Folder); File.WriteAllText(Path.Combine(Folder, "last.txt"), id); }
            catch (Exception) { }
        }

        public static Dictionary<string, string> LoadTarget()
        {
            var d = new Dictionary<string, string>();
            try
            {
                var p = Path.Combine(Folder, "target.txt");
                if (!File.Exists(p)) return d;
                foreach (string line in File.ReadAllLines(p))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0) d[line.Substring(0, eq)] = line.Substring(eq + 1);
                }
            }
            catch (Exception) { }
            return d;
        }

        public static void SaveTarget(Dictionary<string, string> d)
        {
            try
            {
                Directory.CreateDirectory(Folder);
                var lines = new List<string>();
                foreach (var kv in d) lines.Add(kv.Key + "=" + kv.Value);
                File.WriteAllLines(Path.Combine(Folder, "target.txt"), lines.ToArray());
            }
            catch (Exception) { }
        }
    }
}
