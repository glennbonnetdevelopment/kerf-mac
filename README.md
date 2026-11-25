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

## Build and run

Requires macOS 14 or newer and Xcode 15 or newer.

```sh
swift build
swift test          # core geometry, import, G-code, HPGL and streaming tests
swift run Kerf      # launches the app
```

Or open `Package.swift` in Xcode and run the **Kerf** scheme.

## Layout

| Path | What it holds |
| --- | --- |
| `Sources/KerfCore` | UI-free core: geometry, SVG/DXF import, planner, G-code and plotter output, GRBL protocol, serial port |
| `Sources/Kerf` | SwiftUI app: canvas, panels, device controllers |
| `Tests/KerfCoreTests` | Unit tests for the core |

## Safety

Lasers can start fires and damage eyes. Never leave a running laser unattended, wear eye protection
rated for your laser's wavelength, and keep the **Stop** button (or your machine's emergency stop) in reach.
