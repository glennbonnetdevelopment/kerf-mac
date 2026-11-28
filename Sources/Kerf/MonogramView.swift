import KerfCore
import SwiftUI

/// Monogram sheet: pick a template, type the initials, choose the font, size and frame, then add it to the design.
struct MonogramView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    struct FontChoice: Hashable {
        var name: String
        var title: String
        init(_ name: String, _ title: String) {
            self.name = name
            self.title = title
        }
    }

    /// Fonts that suit monograms, by PostScript name. Missing fonts fall back to the system font.
    static let fonts: [FontChoice] = [
        FontChoice("Didot-Bold", "Didot Bold"),
        FontChoice("BodoniSvtyTwoITCTT-Bold", "Bodoni 72 Bold"),
        FontChoice("Baskerville-Bold", "Baskerville Bold"),
        FontChoice("Georgia-Bold", "Georgia Bold"),
        FontChoice("TimesNewRomanPS-BoldMT", "Times New Roman Bold"),
        FontChoice("Copperplate-Bold", "Copperplate Bold"),
        FontChoice("Futura-Bold", "Futura Bold"),
        FontChoice("AvenirNext-Heavy", "Avenir Next Heavy"),
        FontChoice("SnellRoundhand-Black", "Snell Roundhand (script)"),
        FontChoice("Zapfino", "Zapfino (script)"),
    ]

    var body: some View {
        let o = model.monogram.sanitized
        let pieces = model.monogramPieces(o)
        VStack(alignment: .leading, spacing: 12) {
            Text("Monogram").font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    MonogramPreview(pieces: pieces)
                        .frame(width: 320, height: 320)
                    let b = pieces.flatMap(\.placedPaths).bounds
                    if !b.isEmpty {
                        Text(String(format: "%.1f × %.1f mm", b.width, b.height))
                            .font(.callout.monospacedDigit())
                    }
                    Text(o.letters.reshapesLetters
                         ? "Circle and diamond letters are reshaped, so they become outlines rather than editable text."
                         : "The letters stay editable text: select one and type to change it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 320)
                Form {
                    Section("Template") { templateGrid(o) }
                    lettersSection(o)
                    Section("Style") {
                        Picker("Letters", selection: $model.monogram.letters) {
                            ForEach(MonogramLetters.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Frame", selection: $model.monogram.frame) {
                            ForEach(MonogramFrame.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Font", selection: $model.monogram.fontName) {
                            ForEach(fontChoices, id: \.name) { Text($0.title).tag($0.name) }
                        }
                        number("Width (mm)", $model.monogram.size)
                        if o.frame != .none {
                            number("Frame band (mm)", $model.monogram.frameWidth)
                        }
                        if o.letters == .classic {
                            LabeledContent("Side letters") {
                                Slider(value: $model.monogram.sideScale, in: 0.4...1) {
                                    EmptyView()
                                } minimumValueLabel: { Text("40%").font(.caption) } maximumValueLabel: { Text("100%").font(.caption) }
                                    .frame(width: 180)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: 420, height: 540)
            }
            HStack {
                Text("Letters and frame go on their own layers, so they can be sewn or cut in different colours. Undo removes the monogram.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Monogram") {
                    if model.addMonogram() { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(pieces.isEmpty)
            }
        }
        .padding(16)
    }

    private var fontChoices: [FontChoice] {
        var list = Self.fonts
        for extra in [model.monogram.fontName, model.fontName] where !list.contains(where: { $0.name == extra }) && !extra.isEmpty {
            list.append(FontChoice(extra, extra))
        }
        return list
    }

    @ViewBuilder
    private func lettersSection(_ o: MonogramOptions) -> some View {
        Section("Initials") {
            switch o.letters {
            case .single:
                letterField("Initial", $model.monogram.center)
            case .arched:
                letterField("Initial", $model.monogram.center)
                TextField("Name", text: $model.monogram.name)
            default:
                HStack(spacing: 12) {
                    letterField("Left", $model.monogram.left)
                    letterField(o.letters == .block ? "Middle" : "Middle (large)", $model.monogram.center)
                    letterField("Right", $model.monogram.right)
                }
                Text(o.letters == .classic
                     ? "Traditional order: first name, LAST name in the middle, middle name. For a couple: her first, shared LAST, his first."
                     : "Initials in the order you read them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func letterField(_ title: String, _ value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: Binding(get: { value.wrappedValue },
                                        set: { value.wrappedValue = String($0.trimmingCharacters(in: .whitespaces).suffix(1)) }))
                .frame(width: 44)
                .multilineTextAlignment(.center)
        }
    }

    private func templateGrid(_ o: MonogramOptions) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(70), spacing: 8), count: 5), spacing: 8) {
            ForEach(MonogramTemplate.all) { t in
                let applied = t.applied(to: o)
                let selected = o.letters == t.letters && o.frame == t.frame && o.fontName == t.fontName
                Button { model.monogram = t.applied(to: model.monogram) } label: {
                    VStack(spacing: 2) {
                        MonogramPreview(pieces: model.monogramPieces(applied), background: false)
                            .frame(width: 60, height: 60)
                        Text(t.title).font(.system(size: 9)).lineLimit(2).multilineTextAlignment(.center)
                            .frame(height: 22, alignment: .top)
                    }
                    .padding(3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3)))
                }
                .buttonStyle(.plain)
                .help(t.title)
            }
        }
    }

    private func number(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...1))).frame(width: 70)
        }
    }
}

/// The monogram drawn filled: letters in navy, frame in gold.
struct MonogramPreview: View {
    let pieces: [MonogramPiece]
    var background = true

    var body: some View {
        Canvas { ctx, size in
            if background {
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8), with: .color(Color(white: 0.96)))
            }
            let b = pieces.flatMap(\.placedPaths).bounds
            guard !b.isEmpty, b.width > 0, b.height > 0 else { return }
            let scale = min(size.width / b.width, size.height / b.height) * (background ? 0.86 : 0.94)
            let ox = size.width / 2 - b.center.x * scale, oy = size.height / 2 - b.center.y * scale
            func path(_ polys: [Polyline]) -> Path {
                var p = Path()
                for poly in polys where poly.points.count > 1 {
                    p.move(to: CGPoint(x: ox + poly.points[0].x * scale, y: oy + poly.points[0].y * scale))
                    for q in poly.points.dropFirst() { p.addLine(to: CGPoint(x: ox + q.x * scale, y: oy + q.y * scale)) }
                    if poly.closed { p.closeSubpath() }
                }
                return p
            }
            for piece in pieces {
                let color = piece.role == .letters ? Color(hex: "#1E3A8A") : Color(hex: "#B45309")
                let polys = piece.placedPaths
                if piece.weld {
                    // Overlapping parts (stem and leaves): fill each on its own so overlaps don't cancel.
                    for p in polys { ctx.fill(path([p]), with: .color(color)) }
                } else {
                    ctx.fill(path(polys), with: .color(color), style: FillStyle(eoFill: true))
                }
            }
        }
    }
}
