import KerfCore
import SwiftUI

/// Machine tab setting that mirrors the job on its way to the machine, for heat-transfer vinyl
/// (cut face down) and carved or engraved stamps. The design itself isn't changed.
struct MirrorOutputPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("Mirror output", selection: $model.mirrorOutput) {
            ForEach(OutputMirror.allCases) { Text($0.title).tag($0) }
        }
        .help("Flip the job as it is sent or exported, for heat-transfer vinyl or stamps. The design isn't changed.")
        if model.mirrorOutput != .none {
            Label("Output is mirrored \(model.mirrorOutput == .horizontal ? "left to right" : "top to bottom"). The canvas still shows the design as drawn.",
                  systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
