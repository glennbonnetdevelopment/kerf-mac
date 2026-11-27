# Kerf

A native macOS app for designing and running jobs on **GRBL laser engravers** and **vinyl cutters**.
Import SVG or DXF artwork, organise it into colour-coded layers with machine settings, and send it
straight to the machine over USB.

> Kerf is an original app. It follows the familiar "layers → frame → start" workflow of desktop laser
> software but shares no code, artwork or branding with any other product.

## Features (MVP)

- **Import** SVG (paths, shapes, transforms, real-world units) and DXF (lines, arcs, circles,
  ellipses, polylines with bulges, splines). Colours become layers.
- **Canvas** sized to the machine bed: zoom, pan (two-finger scroll or Option-drag), select,
  marquee select, move, nudge with arrow keys, rectangle/ellipse/line tools, text to outlines.
- **Arrange**: exact position and size, rotate, mirror, duplicate, centre on bed, undo/redo.
- **Layers**: Line, Fill (scanline engraving) or Cut (vinyl); speed, power, passes, air assist,
  fill interval and angle, cutter speed and force.
- **GRBL lasers**: port picker, connect, live status and position, home, unlock, jog pad,
  set origin, frame, start / pause / resume / stop, console. Streams with GRBL's
  character-counting protocol and uses `M4` dynamic power (laser mode `$32=1`).
- **Vinyl cutters**: HPGL or GP-GL, blade offset compensation, overcut, weeding border,
  inner-shapes-first ordering. Send over USB serial or to a raw macOS printer queue
  (for cutters like the GCC Expert 24 that show up as USB printers). SVG export for
  machines without a live protocol (Brother ScanNCut).
- **Device presets**: xTool D1 Pro (with and without extension kit), generic GRBL, GCC Expert 24,
  Redsail, EasyCut-class cutters, Janome Artistic Edge (experimental), Brother ScanNCut mats.
  Check the bed size and origin of each preset against your machine.
- **Toolpath preview** with travel moves and estimated job time. Export `.gc`, `.plt` or `.svg`.
- **Rhinestone templates** (Arrange > Rhinestone Layout, ⌥⌘K): lays SS6–SS20 stones along the outline
  (inside it or centred on it, one or more rows) and fills shapes and text with honeycomb, grid or contour
  rows, with optional smaller stones in the gaps. Outline, fill and gap stones can each have their own size
  and colour; each size and colour becomes its own layer of template holes (stone size plus a clearance)
  to cut in flock or rubber on the vinyl cutter or laser. A live preview shows the stone count per colour.
- **Embroidery machines** (File > Export Embroidery, ⌥⌘E): turns the design into stitches and writes
  Brother/Baby Lock `.pes`, Janome `.jef` or Tajima `.dst`. Each layer is a thread colour. **Auto
  (digitize)**, the default, picks per shape: narrow parts of filled shapes become satin columns
  that turn with each stroke (good for lettering), wide parts get tatami fill, and SVG strokes are
  sewn by their width (satin from 1.2 mm, triple from 0.6 mm, otherwise running). Areas are sewn
  before lines, nearest first, and layers of the same colour are grouped when nothing in between
  overlaps them. Layers can also be set to running, triple (bean), satin border, satin columns or
  fill, with underlay, pull compensation, tie stitches and trims. Colours are matched to the Brother
  and Janome thread charts; the preview shows the stitches in the chosen hoop. Hoop sizes are also
  workpiece presets so you can lay out in the hoop.
  **Hand tweaking**: give any shape its own stitch type, density, angle and underlay (Arrange >
  Embroidery), set the sewing order yourself (turn off "Optimize order" in the export window), and
  edit stitches point by point in the stitch editor (move, add, delete, nudge with arrow keys, split
  or join runs). Edited stitches are saved with the shape and sewn exactly as edited.

## KerfSender for older computers

Send-only companion apps for Windows 7/10 and macOS 10.12 live in [`senders/`](senders/README.md).
Export a job with **File › Export for KerfSender…** and open it there.

## Build and run

Requires macOS 14 or newer and Xcode 15 or newer.

```sh
swift build
swift test          # core geometry, import, G-code, HPGL and streaming tests
swift run KerfKutter   # launches the app
```

### Xcode

Open **`KerfKutter.xcodeproj`** and run the **KerfKutter** scheme (⌘R); ⌘U runs the tests. The project has three
targets: the `KerfKutter` app (bundle ID `com.glennbonnetdevelopment.KerfKutter`), the `KerfCore` framework
it embeds, and `KerfCoreTests`. It signs to run locally with no team set. To sign with your Apple team, put
your team ID in `scripts/team-id.txt` (git-ignored) and regenerate the project, so the setting survives
regeneration. The app is
not sandboxed, because the sandbox blocks access to USB serial ports.

After adding or removing Swift files, regenerate the project with `python3 scripts/generate_xcodeproj.py`
(the Swift package picks up new files automatically).

## Layout

| Path | What it holds |
| --- | --- |
| `Sources/KerfCore` | UI-free core: geometry, SVG/DXF import, planner, G-code and plotter output, GRBL protocol, serial port |
| `Sources/Kerf` | SwiftUI app: canvas, panels, device controllers |
| `Tests/KerfCoreTests` | Unit tests for the core |

## Safety

Lasers can start fires and damage eyes. Never leave a running laser unattended, wear eye protection
rated for your laser's wavelength, and keep the **Stop** button (or your machine's emergency stop) in reach.
