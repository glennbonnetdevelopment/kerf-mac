# KerfSender

Small "send only" apps for older computers in the workshop. They open a job exported from
KerfKutter and stream it to the machine. There is no editing: design in KerfKutter, export,
then send from the old computer.

| App | Runs on | Built with |
| --- | --- | --- |
| `windows/KerfSender` | Windows 7 SP1, 8.1, 10 and 11 | C# WinForms on .NET Framework 4.0 (no installer, one `.exe`) |
| `mac` | macOS 10.12 Sierra and later (Intel and Apple silicon) | Objective-C and AppKit, built with command-line clang |

Both support:

- **GRBL lasers and CNC routers** (xTool D1 Pro, 40 W CO2 on GRBL, SainSmart 4040 Pro): port
  picker, connect, live state and position, home, unlock, jog (X/Y, plus Z for CNC), set origin,
  go to origin, start, pause/resume, stop (feed hold then soft reset), progress and a log.
  Streaming uses GRBL's character-counting protocol, the same rules as KerfKutter.
- **Vinyl cutters** (GCC Expert 24, Redsail, EasyCut-class): HPGL or GP-GL over a serial port with
  no flow control, RTS/CTS or XON/XOFF, or raw to a printer (Windows printer or a macOS CUPS
  queue, for cutters that install as USB printers). Progress and stop.
- Opening a job by button, drag and drop, or double-click (Windows: pass the file on the command
  line or choose KerfSender in "Open with").
- Plain `.gc`, `.gcode`, `.nc`, `.plt` and `.hpgl` files too. These carry no machine settings, so
  the app guesses and asks you to check them.

- **Camera registration for lasers** (fixed USB camera above the bed): calibrate the lens with a
  printed checkerboard, align the camera to the bed by burning a target and clicking its marks,
  then drag the job's outline onto the material in the live picture and run it there. See
  [Camera registration](#camera-registration).

## Getting a job out of KerfKutter

**File › Export for KerfSender…** (⇧⌘E) writes a `.kerfjob` for the selected machine. Copy it to
the old computer (USB stick, network share) and open it in KerfSender. The machine type, baud
rate, flow control and cutter output are filled in from the KerfKutter machine profile.

Jobs that start "from the current head position" are written from the work origin (the same as
**Export Machine File**), so jog the head where you want the job and press **Set origin here**
before **Start**.

Brother ScanNCut profiles have no live connection, so they can't be exported for KerfSender.

### The `.kerfjob` format (version 1)

UTF-8 JSON. `data` is the exact text to send. Senders ignore keys they don't know, and refuse a
`version` newer than they understand.

```json
{
  "format": "kerfjob",
  "version": 1,
  "name": "coaster",
  "created": "2026-11-25T10:00:00Z",
  "generator": "KerfKutter",
  "machine": {
    "name": "xTool D1 Pro",
    "kind": "grblLaser",          // grblLaser | cncRouter | vinylCutter
    "language": "gcode",          // gcode | hpgl | gpgl
    "baudRate": 115200,
    "flowControl": "none",        // none | hardware | software
    "rxBufferSize": 127,
    "output": "serial",           // serial | printerQueue
    "bedWidth": 432,
    "bedHeight": 406
  },
  "estimatedSeconds": 754,
  "lineCount": 5120,
  "data": "G21\nG90\n…"
}
```

Sample jobs used by the tests are in `samples/`.

## Camera registration

The same workflow as KerfKutter's **View › Camera**, for a USB camera fixed above the laser bed.
Open it with the **Camera…** button (Mac: also **Window › Camera…**, ⌥⌘C). Each camera remembers its
own calibration (Windows: `%APPDATA%\KerfSender\camera\`, Mac: the app's preferences).

1. **Lens** (optional, recommended): print a checkerboard, enter its inner corner count (a board of
   10 × 7 squares has 9 × 6), and press **Capture board** with it in 8 to 15 places: middle, edges,
   corners, some tilted. Then **Calibrate lens**. This removes the barrel distortion of webcam lenses.
2. **Alignment**: home the laser, cover the bed with card or plywood, set the bed size, margin and a
   low power, and **Burn target…**. It burns a grid of marks (cross in a circle; mark 1 has an
   inner ring and is the one nearest X 0, Y 0). **Take snapshot**, click the marks in order
   (clicks snap to the centre; after three, **Find the rest** finds the others), then **Save
   alignment**. Redo this if the camera or its mount moves.
3. **Place job**: the job's outline is drawn on the live picture where it will burn, and a red
   cross shows the laser head. Drag the outline onto the material (or type a move and a turn).
   With **Run the job where it's placed** ticked, **Start** in the main window sends the job moved
   and turned to that spot. Jog the head and check the red cross follows it to confirm the alignment.

Positions are tied to the machine itself: the target is burned in work coordinates and stored in
machine coordinates using the work offset GRBL reports (`WCO`), so a later **Set origin here**
doesn't break the alignment. The machine must be homed (or its origin otherwise repeatable) so
machine coordinates mean the same place each session. Jobs that use relative moves (G91) can't be
placed. Burning the target needs a GRBL laser; full power is `$30` (usually 1000).

Windows captures through DirectShow (built into Windows 7 to 11, no download); the Mac uses
AVFoundation (macOS 10.12 and later; on 10.14 and later macOS asks for camera permission the
first time). Both use the camera's largest picture up to 1920 × 1080.

## Windows: build and test

You don't need a Windows machine to build it.

- **GitHub Actions**: every push that touches `senders/windows` runs the
  "KerfSender for Windows" workflow. Open the run and download the `KerfSender-windows`
  artifact; it contains `KerfSender.exe`. You can also start it by hand from the Actions tab
  ("Run workflow").
- **Any computer with the .NET SDK** (Windows, Mac or Linux):

  ```sh
  dotnet run --project senders/windows/SelfTest        # checks the job reader, streaming rules and camera maths
  dotnet build senders/windows/KerfSender -c Release   # writes bin/Release/net40/KerfSender.exe
  ```

To run it, copy `KerfSender.exe` to the Windows computer and double-click it. Nothing to install
on Windows 10 or 11. On Windows 7 it needs .NET Framework 4.x: most Windows 7 SP1 machines already
have it through Windows Update; if not, install .NET Framework 4.8 from Microsoft. Windows may
show a SmartScreen warning because the exe isn't signed: choose **More info › Run anyway**.

USB serial drivers: the xTool and most GRBL boards use a CH340 or CP210x chip. Windows 10
installs these itself; on Windows 7 install the CH340 or CP210x driver first, then check the COM
number in Device Manager › Ports. For a GCC cutter on the printer route, install GCC's Windows
driver so the cutter shows up as a printer, then choose **Send to: Windows printer**.

Testing without a machine: open a sample from `senders/samples/`; with no port the Start button
stays disabled. A free virtual COM pair (com0com) plus a GRBL simulator lets you test streaming
end to end.

## Mac 10.12: build and test

Current Xcode can't target 10.12 for Swift or SwiftUI apps, so this sender is plain
Objective-C and AppKit, built by a script with command-line clang. Any recent Xcode works:

```sh
senders/mac/build.sh
```

It writes `senders/mac/build/KerfSender.app` and `KerfSender-mac.zip`. `senders/mac/build.sh test`
runs the camera and toolpath self-tests instead (the camera maths in `KSCameraMath.c` is plain C, so
`senders/mac/Tests/camera_math_test.c` also builds with any C compiler). The Intel part targets
macOS 10.12 and the Apple silicon part 11.0, so the same app runs on the old Mac and on new ones.
Copy the zip to the 10.12 Mac, unzip it, then right-click the app and choose **Open** the first
time (it is ad-hoc signed, not notarised).

For cutters on the printer route, add the cutter in System Preferences › Printers & Scanners
(Generic PostScript is fine, the data is sent raw) and choose **Send to: Printer queue**.
