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

## Windows: build and test

You don't need a Windows machine to build it.

- **GitHub Actions**: every push that touches `senders/windows` runs the
  "KerfSender for Windows" workflow. Open the run and download the `KerfSender-windows`
  artifact; it contains `KerfSender.exe`. You can also start it by hand from the Actions tab
  ("Run workflow").
- **Any computer with the .NET SDK** (Windows, Mac or Linux):

  ```sh
  dotnet run --project senders/windows/SelfTest        # checks the job reader and streaming rules
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

It writes `senders/mac/build/KerfSender.app` and `KerfSender-mac.zip`. The Intel part targets
macOS 10.12 and the Apple silicon part 11.0, so the same app runs on the old Mac and on new ones.
Copy the zip to the 10.12 Mac, unzip it, then right-click the app and choose **Open** the first
time (it is ad-hoc signed, not notarised).

For cutters on the printer route, add the cutter in System Preferences › Printers & Scanners
(Generic PostScript is fine, the data is sent raw) and choose **Send to: Printer queue**.
