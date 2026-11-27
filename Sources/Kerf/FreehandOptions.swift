import KerfCore
import SwiftUI

/// Settings for the pen, brush and eraser, shown under their toolbar buttons.
struct FreehandOptions: View {
    @EnvironmentObject var model: AppModel
    let tool: Tool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch tool {
            case .pen:
                Text("Pen").font(.headline)
                smoothing
                Text("Drag to draw. The line is smoothed into a clean path you can cut, score or stitch along. End near where you started to close the shape.")
                    .modifier(Caption())
            case .brush:
                Text("Brush").font(.headline)
                sizeRow("Width", $model.freehand.brushWidth, range: 0.2...50)
                HStack {
                    Text("Thinning")
                    Slider(value: $model.freehand.brushThinning, in: 0...1)
                    Text("\(Int(model.freehand.brushThinning * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                .help("How much moving fast (or pressing lightly with a pen) makes the stroke thinner")
                Toggle("Taper the ends", isOn: $model.freehand.brushTaper)
                Toggle("Use pen pressure", isOn: $model.freehand.brushPressure)
                    .help("With a drawing tablet or Force Touch trackpad, pressing harder makes a wider stroke")
                smoothing
                Text("Each stroke becomes a filled outline: engrave it on a fill layer, cut around it on a line or vinyl layer, or fill it with stitches.")
                    .modifier(Caption())
            case .eraser:
                Text("Eraser").font(.headline)
                sizeRow("Size", $model.freehand.eraserSize, range: 0.2...100)
                Picker("Erase", selection: $model.freehand.eraserMode) {
                    ForEach(EraserMode.allCases) { Text($0.title).tag($0) }
                }
                Text(model.freehand.eraserMode.help).modifier(Caption())
                Toggle("Only the selected shapes", isOn: $model.freehand.eraserSelectionOnly)
                    .help("Select shapes first with the arrow tool; the eraser then leaves everything else alone")
                Text("Images aren't erased. Erased text turns into plain outlines.").modifier(Caption())
            default:
                EmptyView()
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var smoothing: some View {
        HStack {
            Text("Smoothing")
            Slider(value: $model.freehand.smoothing, in: 0...1)
            Text("\(Int(model.freehand.smoothing * 100))%").monospacedDigit().frame(width: 38, alignment: .trailing)
        }
        .help("Low follows your hand exactly; high irons out wobble")
    }

    /// A size in the workspace units, stored in mm.
    private func sizeRow(_ label: String, _ value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        let u = model.units
        return HStack {
            Text(label)
            Slider(value: Binding(get: { min(range.upperBound, max(range.lowerBound, value.wrappedValue)) },
                                  set: { value.wrappedValue = ($0 * 10).rounded() / 10 }),
                   in: range)
            TextField("", value: Binding(get: { value.wrappedValue / u.mmPerUnit },
                                         set: { value.wrappedValue = max(0.05, $0 * u.mmPerUnit) }),
                      format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 55)
            Text(u.title)
        }
    }
}

private struct Caption: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
