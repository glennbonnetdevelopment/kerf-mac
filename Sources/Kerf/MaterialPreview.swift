import AppKit
import KerfCore
import SwiftUI

/// A rendered carving, passed out of the background task.
private struct CarvingRender: @unchecked Sendable {
    var image: CGImage
    var deepest: Double
    var widthMM: Double
    var heightMM: Double
}

/// Shows the CNC job carved into a block of wood, simulated from the generated G-code.
struct MaterialPreviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var render: CarvingRender?
    @State private var moves: [MillMove] = []
    @State private var progress = 1.0
    @State private var thickness = 18.0
    @State private var showPaths = true
    @State private var busy = false
    @State private var generation = 0
    /// The workpiece in machine coordinates, when one is set.
    @State private var stock: Rect2?

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if model.profile.kind != .cncRouter {
                    Text("Choose a CNC machine in the toolbar to preview carving.")
                        .foregroundStyle(.secondary)
                } else if let render {
                    Image(decorative: render.image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        .padding(24)
                } else if !busy {
                    Text("Nothing to carve yet. Add shapes to an enabled layer.")
                        .foregroundStyle(.secondary)
                }
                if busy { ProgressView().controlSize(.large) }
            }
        }
        .frame(minWidth: 560, minHeight: 460)
        .onAppear { reload() }
        .onChange(of: model.document) { _, _ in reload() }
        .onChange(of: model.activeProfileID) { _, _ in reload() }
        .onChange(of: thickness) { _, _ in rerender() }
        .onChange(of: showPaths) { _, _ in rerender() }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            LabeledContent("Stock thickness (mm)") {
                TextField("", value: $thickness, format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 60)
            }
            Toggle("Show paths", isOn: $showPaths)
            LabeledContent("Progress") {
                Slider(value: $progress, in: 0...1) { editing in
                    if !editing { rerender() }
                }
                .frame(width: 180)
            }
            Spacer()
            if let render {
                Text(String(format: "%.0f × %.0f mm · deepest %.2f mm", render.widthMM, render.heightMM, render.deepest))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { reload() } label: { Image(systemName: "arrow.clockwise") }
                .help("Simulate again")
        }
        .padding(10)
    }

    private func reload() {
        guard model.profile.kind == .cncRouter, !model.toolpath.isEmpty else {
            moves = []
            render = nil
            return
        }
        if let w = model.document.workpiece, w.kind == .stock {
            thickness = w.thickness
            let a = model.profile.toMachine(Vec2(w.x, w.y)), b = model.profile.toMachine(Vec2(w.x + w.width, w.y + w.height))
            stock = Rect2(minX: min(a.x, b.x), minY: min(a.y, b.y), maxX: max(a.x, b.x), maxY: max(a.y, b.y))
        } else {
            stock = nil
            let deepestLayer = model.document.layers.filter(\.enabled).map(\.cutDepth).max() ?? 0
            if thickness < deepestLayer { thickness = max(deepestLayer, 6) }
        }
        moves = MillSimulator.moves(from: model.gcodeLines())
        rerender()
    }

    private func rerender() {
        guard !moves.isEmpty else { render = nil; return }
        generation += 1
        let token = generation
        let all = moves, count = Int((Double(all.count) * progress).rounded())
        let depth = max(0.1, thickness), paths = showPaths, region = stock
        busy = true
        Task.detached(priority: .userInitiated) {
            let result = CarvingRenderer.render(moves: all, upTo: count, thickness: depth, region: region, showPaths: paths)
            await MainActor.run {
                guard token == generation else { return }
                render = result
                busy = false
            }
        }
    }
}

private enum CarvingRenderer {
    static func render(moves: [MillMove], upTo count: Int, thickness: Double, region: Rect2?, showPaths: Bool) -> CarvingRender? {
        var sim = region.map { MillSimulator(region: $0) } ?? MillSimulator(moves: moves)
        sim.run(moves.prefix(count))
        let w = sim.columns, h = sim.rows
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        let light = normalize3(-0.45, 0.55, 0.75)
        let flat = light.2
        let heights = sim.heights
        for j in 0..<h {
            // Image row 0 is the top, which is the highest machine Y.
            let row = h - 1 - j
            for i in 0..<w {
                let idx = j * w + i
                let z = Double(heights[idx])
                let depth = -z
                let x = sim.originX + (Double(i) + 0.5) * sim.cell
                let y = sim.originY + (Double(j) + 0.5) * sim.cell
                var c: (Double, Double, Double)
                if depth >= thickness - 1e-3 {
                    c = (0.22, 0.23, 0.25) // spoilboard showing through
                } else {
                    c = wood(x: x, y: y, depth: depth)
                    // Freshly cut wood is a touch lighter and less glossy, then darkens with depth.
                    if depth > 0.01 {
                        let f = min(1, depth / thickness)
                        c = (c.0 * (1.02 - 0.3 * f), c.1 * (1.0 - 0.33 * f), c.2 * (0.96 - 0.36 * f))
                    }
                }
                // Light from the upper left using the surface slope.
                let zl = Double(heights[j * w + max(0, i - 1)]), zr = Double(heights[j * w + min(w - 1, i + 1)])
                let zd = Double(heights[max(0, j - 1) * w + i]), zu = Double(heights[min(h - 1, j + 1) * w + i])
                let n = normalize3(-(zr - zl) / (2 * sim.cell), -(zu - zd) / (2 * sim.cell), 1)
                let lambert = max(0, n.0 * light.0 + n.1 * light.1 + n.2 * light.2)
                let shade = 0.25 + 0.75 * lambert / flat
                let p = (row * w + i) * 4
                pixels[p] = UInt8(max(0, min(255, c.0 * shade * 255)))
                pixels[p + 1] = UInt8(max(0, min(255, c.1 * shade * 255)))
                pixels[p + 2] = UInt8(max(0, min(255, c.2 * shade * 255)))
                pixels[p + 3] = 255
            }
        }

        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CGContext's origin is the bottom-left, matching machine coordinates.
        ctx.translateBy(x: -sim.originX / sim.cell, y: -sim.originY / sim.cell)
        ctx.scaleBy(x: 1 / sim.cell, y: 1 / sim.cell)
        if showPaths {
            ctx.setLineWidth(max(0.15, sim.cell * 1.2))
            ctx.setLineCap(.round)
            for m in moves.prefix(count) {
                ctx.move(to: CGPoint(x: m.from.x, y: m.from.y))
                ctx.addLine(to: CGPoint(x: m.to.x, y: m.to.y))
                if m.feed && min(m.from.z, m.to.z) < 0 {
                    ctx.setStrokeColor(CGColor(red: 0.85, green: 0.15, blue: 0.1, alpha: 0.55))
                    ctx.setLineDash(phase: 0, lengths: [])
                } else {
                    ctx.setStrokeColor(CGColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 0.35))
                    ctx.setLineDash(phase: 0, lengths: [sim.cell * 6, sim.cell * 4])
                }
                ctx.strokePath()
            }
        }
        // Tool position at the current progress.
        if count > 0, count < moves.count {
            let m = moves[count - 1]
            let r = m.toolDiameter / 2
            ctx.setFillColor(CGColor(red: 0.75, green: 0.78, blue: 0.82, alpha: 0.9))
            ctx.fillEllipse(in: CGRect(x: m.to.x - r, y: m.to.y - r, width: 2 * r, height: 2 * r))
            ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 1))
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setLineWidth(sim.cell)
            ctx.strokeEllipse(in: CGRect(x: m.to.x - r, y: m.to.y - r, width: 2 * r, height: 2 * r))
        }
        guard let image = ctx.makeImage() else { return nil }
        return CarvingRender(image: image, deepest: Double(-sim.deepest),
                             widthMM: Double(w) * sim.cell, heightMM: Double(h) * sim.cell)
    }

    /// Procedural board: long grain along X with growth rings, a little figure, and fine pores.
    /// The ring pattern shifts with depth, so carved areas show the grain lower in the board.
    static func wood(x: Double, y: Double, depth: Double) -> (Double, Double, Double) {
        let warp = fbm(x * 0.012, y * 0.05) * 9 + fbm(x * 0.05, y * 0.2) * 1.5
        let ringPos = (y + depth * 2.2) * 0.42 + warp
        let ring = ringPos - ringPos.rounded(.down)
        let late = pow(ring, 3.5) // dark latewood at the end of each ring
        let pores = fbm(x * 0.9, y * 6) * 0.08
        let t = min(1, late * 0.75 + pores + fbm(x * 0.004, y * 0.01) * 0.15)
        let lightWood = (0.89, 0.74, 0.54), darkWood = (0.66, 0.45, 0.26)
        return (lightWood.0 + (darkWood.0 - lightWood.0) * t,
                lightWood.1 + (darkWood.1 - lightWood.1) * t,
                lightWood.2 + (darkWood.2 - lightWood.2) * t)
    }

    static func normalize3(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        let l = max(1e-12, (x * x + y * y + z * z).squareRoot())
        return (x / l, y / l, z / l)
    }

    static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt64(bitPattern: Int64(x &* 374_761_393 &+ y &* 668_265_263))
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Double(h & 0xFFFF) / 65535
    }

    static func noise(_ x: Double, _ y: Double) -> Double {
        let xi = Int(x.rounded(.down)), yi = Int(y.rounded(.down))
        let fx = x - Double(xi), fy = y - Double(yi)
        let u = fx * fx * (3 - 2 * fx), v = fy * fy * (3 - 2 * fy)
        let a = hash(xi, yi), b = hash(xi + 1, yi), c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
        return (a + (b - a) * u) + ((c + (d - c) * u) - (a + (b - a) * u)) * v
    }

    static func fbm(_ x: Double, _ y: Double) -> Double {
        var sum = 0.0, amp = 0.5, fx = x, fy = y
        for _ in 0..<4 {
            sum += noise(fx, fy) * amp
            fx *= 2.03
            fy *= 2.03
            amp *= 0.5
        }
        return sum
    }
}
