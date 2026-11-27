import KerfCore
import SwiftUI

/// Stroke, fill and offset controls for the selected shapes, as a section of a grouped form.
struct ShapeStyleSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Section("Style") {
            ShapeStyleControls()
        }
    }
}

/// The style rows themselves, shared by the Arrange panel and the toolbar's Style popover.
struct ShapeStyleControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.styleTargets.isEmpty {
            Text("Select a shape to round its corners or add a stroke, fill or offset outline.")
                .foregroundStyle(.secondary)
        } else {
            LabeledContent {
                TextField("", value: Binding(get: { model.selectionCornerRadius }, set: { model.setCornerRadius($0) }),
                          format: .number.precision(.fractionLength(0...2)))
                    .frame(width: 70)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "app")
                        .frame(width: 16)
                    Text("Corner radius (mm)")
                }
            }
            .help("Rounds the shape's sharp corners. 0 keeps them sharp.")
            ForEach(StylePartKind.allCases) { kind in
                StylePartRow(kind: kind)
            }
            Toggle("Make the shape's own outline", isOn: Binding(
                get: { model.selectionOutlineEnabled },
                set: { model.setOutlineEnabled($0) }))
                .disabled(!StylePartKind.allCases.contains { model.isStyleEnabled($0) })
                .help("Turn off to make only the styles, for example just the stroke")
            Text("Each style you turn on goes on its own layer under the shape's layer, so it can be engraved, cut or sewn with its own settings. Its colour is that layer's colour.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StylePartRow: View {
    @EnvironmentObject var model: AppModel
    let kind: StylePartKind

    var body: some View {
        let part = model.stylePart(kind)
        let on = part?.enabled ?? false
        Toggle(isOn: Binding(get: { on }, set: { model.setStyle(kind, enabled: $0) })) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .frame(width: 16)
                Text(kind.title)
            }
        }
        if on, let part, let layer = model.document.layer(part.layerID) {
            if let title = kind.amountTitle {
                LabeledContent(title) {
                    TextField("", value: Binding(get: { part.amount }, set: { model.setStyleAmount(kind, $0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 70)
                }
                .padding(.leading, 22)
            }
            LabeledContent("Layer") {
                HStack(spacing: 6) {
                    ColorPicker("", selection: Binding(
                        get: { Color(hex: layer.colorHex) },
                        set: { model.setStyleColor(kind, $0.hexString) }), supportsOpacity: false)
                        .labelsHidden()
                        .help("\(kind.title) colour")
                    Menu {
                        ForEach(model.document.layers) { l in
                            Button { model.setStyleLayer(kind, l.id) } label: {
                                Text(l.id == layer.id ? "✓ \(l.name)" : l.name)
                            }
                        }
                        Divider()
                        Button("New layer for this \(kind.title.lowercased())") { model.moveStyleToNewLayer(kind) }
                    } label: {
                        Text("\(layer.name) · \(layer.mode.title)").lineLimit(1)
                    }
                    .frame(maxWidth: 190)
                }
            }
            .padding(.leading, 22)
        }
    }

    private var symbol: String {
        switch kind {
        case .stroke: return "lineweight"
        case .fill: return "square.fill"
        case .offset: return "square.dashed"
        }
    }
}
