import KerfCore
import SwiftUI

/// File › Screen Print Films: one black film per colour (or a negative for stencils), with registration
/// marks, halftones, spread and choke, knockouts with trap, an underbase and emulsion-side mirroring.
struct ScreenPrintView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The film shown in the preview, or nil for all colours together.
    @State private var shown: Int? = 0
    /// Show the exposure test film in the preview instead of the design's films.
    @State private var showTest = false

    var body: some View {
        let set = showTest ? model.exposureTestFilms : model.screenPrintFilms
        let index = showTest ? 0 : shown.flatMap { set.films.indices.contains($0) ? $0 : nil }
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                settings(set)
                    .frame(width: 370)
                Divider()
                VStack(spacing: 8) {
                    Picker("Show", selection: $shown) {
                        Text("All colours").tag(Int?.none)
                        ForEach(set.films.indices, id: \.self) { i in
                            Text("\(i + 1). \(set.films[i].name)").tag(Int?.some(i))
                        }
                    }
                    .frame(maxWidth: 360)
                    .disabled(showTest)
                    if showTest {
                        Text("Exposure test film").font(.headline)
                    }
                    FilmCanvas(set: set, index: index, background: model.document.workpiece?.colorHex)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .underPageBackgroundColor))
                    if !set.fitsPage {
                        Label("The films don't fit on this paper. Choose bigger paper, landscape, or Fit page to artwork.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            }
            Divider()
            HStack {
                Button("Save Films as PDF…") { model.saveFilmsPDF() }
                    .disabled(set.isEmpty)
                Button("Add Stencil Cut Layers") { model.addStencilMaskLayers() }
                    .disabled(set.isEmpty)
                    .help("Adds each film's outlines as a Cut layer, for cutting a vinyl stencil or blockout mask")
                Spacer()
                Text("\(set.films.count) film\(set.films.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Print Films…") { model.printFilms() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(set.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 900, idealWidth: 1020, minHeight: 620, idealHeight: 720)
    }

    // MARK: Settings

    private func settings(_ set: FilmSet) -> some View {
        Form {
            Section {
                let layers = model.screenPrintLayers
                if layers.isEmpty {
                    Text("No enabled layers with artwork.").foregroundStyle(.secondary)
                }
                ForEach(layers) { layer in
                    SeparationRow(layer: layer)
                }
                Text("One film per colour, printed in the order of the Layers list, top first. Spread (+) grows a colour, choke (−) shrinks it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Colours")
            }

            Section("Overlapping colours") {
                Toggle("Knock out colours underneath", isOn: $model.screenPrint.knockout)
                    .help("Where a colour printed later covers an earlier one, leave the earlier one open so inks don't pile up")
                if model.screenPrint.knockout {
                    mmField("Trap (mm)", $model.screenPrint.trap)
                        .help("How far the colour underneath still runs under the one on top, so a small shift doesn't show bare garment")
                }
                Toggle("White underbase film", isOn: $model.screenPrint.underbase)
                    .help("Printed first on dark garments: every colour together, pulled in so it hides under them")
                if model.screenPrint.underbase {
                    mmField("Underbase choke (mm)", $model.screenPrint.underbaseChoke)
                }
            }

            Section("Film") {
                Toggle("Negative (clear artwork on black)", isOn: $model.screenPrint.invert)
                    .help("For blockout masks and stencils. Leave off for film positives to expose emulsion screens.")
                if model.screenPrint.invert {
                    mmField("Black border (mm)", $model.screenPrint.negativeMargin)
                }
                Toggle("Mirror (emulsion side)", isOn: $model.screenPrint.mirror)
                    .help("Flip left to right, for printing on the back of the film")
                Toggle("Registration marks", isOn: $model.screenPrint.registrationMarks)
                if model.screenPrint.registrationMarks {
                    mmField("Mark size (mm)", $model.screenPrint.markSize)
                    mmField("Gap from artwork (mm)", $model.screenPrint.markMargin)
                }
                Toggle("Label each film", isOn: $model.screenPrint.labels)
            }

            Section("Halftones for images") {
                Picker("Mesh", selection: Binding(get: { model.screenPrint.mesh }, set: { model.applyMesh($0) })) {
                    Text("Custom").tag(Int?.none)
                    ForEach(MeshPreset.all) { Text($0.title).tag(Int?.some($0.mesh)) }
                }
                if let mesh = model.screenPrint.mesh, let preset = MeshPreset.preset(mesh) {
                    Text(preset.use).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Lines per inch") {
                    TextField("", value: Binding(get: { model.screenPrint.halftoneLPI },
                                                 set: { model.screenPrint.halftoneLPI = $0; model.screenPrint.mesh = nil }),
                              format: .number).frame(width: 60)
                }
                .help("35 to 55 suits inkjet film on 156 to 230 mesh. Higher needs finer mesh.")
                LabeledContent("Angle (°)") {
                    TextField("", value: $model.screenPrint.halftoneAngle, format: .number).frame(width: 60)
                }
                .help("22.5° keeps the dots from lining up with the mesh threads (moiré)")
                Picker("Dot", selection: $model.screenPrint.dotShape) {
                    ForEach(HalftoneDotShape.allCases) { Text($0.title).tag($0) }
                }
                Button("Separate a Colour Picture into Inks…") {
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.chooseColorImageToSeparate() }
                }
                Text("Image layers can each have their own angle in the Colours list.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Exposure test film") {
                Stepper("Columns: \(model.screenPrint.testSteps)", value: $model.screenPrint.testSteps, in: 2...12)
                LabeledContent("Shortest exposure (s)") {
                    TextField("", value: $model.screenPrint.testBaseSeconds, format: .number).frame(width: 60)
                }
                LabeledContent("Added per column (s)") {
                    TextField("", value: $model.screenPrint.testStepSeconds, format: .number).frame(width: 60)
                }
                let times = ExposureTest.times(steps: model.screenPrint.testSteps, base: model.screenPrint.testBaseSeconds,
                                               step: model.screenPrint.testStepSeconds)
                Text("Columns get \(ExposureTest.clock(times.first ?? 0)) to \(ExposureTest.clock(times.last ?? 0)). Cover one more column with card every \(ExposureTest.clock(model.screenPrint.testStepSeconds)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Print Test Film…") { model.printFilms(model.exposureTestFilms, name: "Exposure test") }
                    Button("Save as PDF…") { model.saveFilmsPDF(model.exposureTestFilms, name: "Exposure test") }
                    Button(showTest ? "Hide" : "Preview") { showTest.toggle() }
                }
            }

            Section("Paper") {
                Toggle("Fit page to artwork", isOn: $model.screenPrint.fitToArtwork)
                    .help("Make each page just big enough for the film, for film on a roll or a wide-format printer")
                if !model.screenPrint.fitToArtwork {
                    Picker("Size", selection: $model.screenPrint.paper) {
                        ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Orientation", selection: $model.screenPrint.landscape) {
                        Text("Portrait").tag(false)
                        Text("Landscape").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                LabeledContent("Film size", value: set.extent.isEmpty ? "—" :
                                String(format: "%.0f × %.0f mm", set.extent.width, set.extent.height))
                Text("Prints at 100% scale. Use your printer's darkest film or transparency setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func mmField(_ title: String, _ value: Binding<Double>) -> some View {
        LabeledContent(title) {
            TextField("", value: value, format: .number).frame(width: 60)
        }
    }
}

/// A colour in the film list: whether it gets a film, and its spread or choke.
private struct SeparationRow: View {
    @EnvironmentObject var model: AppModel
    let layer: Layer

    private var hasImages: Bool {
        model.document.shapes.contains { $0.layerID == layer.id && $0.image != nil }
    }

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { !model.screenPrint.excludedLayers.contains(layer.id) },
                                     set: { model.setScreenPrintLayer(layer.id, included: $0) }))
                .labelsHidden()
                .toggleStyle(.checkbox)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: layer.colorHex))
                .frame(width: 14, height: 14)
            Text(layer.name).lineLimit(1)
            Spacer()
            TextField("", value: Binding(get: { layer.screenSpread }, set: { model.setScreenSpread(layer.id, $0) }),
                      format: .number)
                .frame(width: 50)
                .help("Spread (+) or choke (−) in mm")
            Text("mm").foregroundStyle(.secondary)
            if hasImages {
                TextField("", value: Binding(get: { layer.screenAngle }, set: { model.setScreenAngle(layer.id, $0) }),
                          format: .number, prompt: Text("\(model.screenPrint.halftoneAngle, specifier: "%g")"))
                    .frame(width: 40)
                    .help("Halftone angle for this colour's images, in degrees. Empty uses the films' angle.")
                Text("°").foregroundStyle(.secondary)
            }
        }
    }
}

/// One film on its page at scale, or every colour together on the garment colour.
private struct FilmCanvas: View {
    let set: FilmSet
    let index: Int?
    let background: String?

    var body: some View {
        Canvas { gc, size in
            let page = set.pageSize
            let pad = 20.0
            let s = max(0.01, min((size.width - pad * 2) / page.x, (size.height - pad * 2) / page.y))
            let w = page.x * s, h = page.y * s
            let origin = CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2)
            let rect = CGRect(origin: origin, size: CGSize(width: w, height: h))
            var shadow = gc
            shadow.addFilter(.shadow(color: .black.opacity(0.25), radius: 6, y: 2))
            let sheet: Color = index == nil ? Color(hex: background ?? "#FFFFFF") : .white
            shadow.fill(Path(rect), with: .color(sheet))
            let offset = set.pageOffset
            gc.withCGContext { ctx in
                ctx.clip(to: rect)
                ctx.translateBy(x: origin.x, y: origin.y)
                ctx.scaleBy(x: s, y: s)
                ctx.translateBy(x: offset.x, y: offset.y)
                if let index {
                    ScreenPrint.draw(index, of: set, in: ctx)
                } else {
                    ScreenPrint.drawComposite(set, in: ctx)
                }
            }
        }
    }
}
