import AppKit
import KerfCore
import SwiftUI

/// File › Print Preview: lays the print artwork and registration marks out on a page at true size,
/// then prints through the macOS print dialog or saves a PDF.
struct PrintPreviewView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let items = model.printItems()
        let settings = model.printSettings
        let page = settings.pageSize
        let content = model.printContentBounds(items: items)
        let offset = model.printOffset(items: items)
        let cuts = settings.showCutLines ? model.printPreviewCuts : nil
        let fits = PrintLayout.fits(content: content, offset: offset, page: page, margin: min(settings.margin, 3))
        let markCount = model.allRegistrationPoints.count

        VStack(spacing: 0) {
            HSplitView {
                PageCanvas(items: items, cuts: cuts, page: page, offset: offset, margin: settings.margin)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                Form {
                    Section("Paper") {
                        Picker("Size", selection: $model.printSettings.paper) {
                            ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Orientation", selection: $model.printSettings.landscape) {
                            Text("Portrait").tag(false)
                            Text("Landscape").tag(true)
                        }
                        .pickerStyle(.segmented)
                        Picker("Position", selection: $model.printSettings.placement) {
                            ForEach(PrintPlacement.allCases) { Text($0.title).tag($0) }
                        }
                        LabeledContent("Margin (mm)") {
                            TextField("", value: $model.printSettings.margin, format: .number).frame(width: 60)
                        }
                        Text("Prints at 100% scale. Turn off \"Scale to fit\" in the print dialog if your printer shows it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Registration marks") {
                        RegistrationSettings()
                        Button(markCount == 0 ? "Add registration marks" : "Replace registration marks") {
                            model.addRegistrationMarks()
                        }
                        Text(markCount == 0 ? "No marks yet. The cutter can't line up the cut without them."
                                            : "\(markCount) marks on the Registration layer.")
                            .font(.caption)
                            .foregroundStyle(markCount == 0 ? .orange : .secondary)
                    }
                    Section("Cut lines") {
                        Toggle("Show cut lines in preview", isOn: $model.printSettings.showCutLines)
                        Toggle("Print cut lines (test sheet)", isOn: $model.printSettings.printCutLines)
                            .help("Prints the cut path as a thin red line, so you can check the cutter lands on it")
                    }
                    Section("Check") {
                        LabeledContent("Job size", value: content.isEmpty ? "—" :
                                        String(format: "%.0f × %.0f mm", content.width, content.height))
                        if !fits {
                            Label("The job doesn't fit on this page. Choose bigger paper or landscape.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        if model.registrationStyle == .gccAAS || model.profile.aasEnabled {
                            let marks = model.allRegistrationPoints.reduce(Rect2.empty) { r, p in
                                var r = r
                                r.include(p)
                                return r
                            }
                            ForEach(GCCAAS.layoutWarnings(marks: marks, page: page, offset: offset), id: \.self) { w in
                                Label(w, systemImage: "info.circle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
            }
            Divider()
            HStack {
                Button("Save as PDF…") { model.savePrintPagePDF() }
                    .disabled(items.isEmpty)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Print…") { model.printSheet() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 820, minHeight: 600)
    }
}

/// The page drawn to scale, with the margin shown dashed.
private struct PageCanvas: View {
    var items: [PrintItem]
    var cuts: [[Vec2]]?
    var page: Vec2
    var offset: Vec2
    var margin: Double

    var body: some View {
        Canvas { gc, size in
            let pad = 24.0
            let s = max(0.01, min((size.width - pad * 2) / page.x, (size.height - pad * 2) / page.y))
            let w = page.x * s, h = page.y * s
            let origin = CGPoint(x: (size.width - w) / 2, y: (size.height - h) / 2)
            let rect = CGRect(origin: origin, size: CGSize(width: w, height: h))
            var shadow = gc
            shadow.addFilter(.shadow(color: .black.opacity(0.25), radius: 6, y: 2))
            shadow.fill(Path(rect), with: .color(.white))
            let inner = rect.insetBy(dx: margin * s, dy: margin * s)
            if inner.width > 0, inner.height > 0 {
                gc.stroke(Path(inner), with: .color(.gray.opacity(0.5)), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
            }
            gc.withCGContext { ctx in
                ctx.clip(to: rect)
                ctx.translateBy(x: origin.x, y: origin.y)
                ctx.scaleBy(x: s, y: s)
                ctx.translateBy(x: offset.x, y: offset.y)
                AppModel.drawPrint(items, cuts: cuts, cutLineWidth: max(0.15, 1 / s), in: ctx)
            }
        }
    }
}
