import KerfCore
import SwiftUI

/// File › Separate Colour Picture into Inks: picks spot ink colours from a photo and makes one image layer
/// per ink, which the screen print films turn into halftoned films.
struct ColorSeparationView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: ColorSeparationSource

    @State private var count = 4
    @State private var garmentPrints = false
    @State private var garment = Color.white
    @State private var smoothing = 0.5
    @State private var inks: [InkColor] = []
    @State private var small: ColorImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                Form {
                    Section("Inks") {
                        Stepper("Ink colours: \(count)", value: $count, in: 1...8)
                        ForEach(inks.indices, id: \.self) { k in
                            ColorPicker("Ink \(k + 1) (\(inks[k].hex))", selection: inkBinding(k), supportsOpacity: false)
                        }
                        Button("Pick colours again") { pickInks() }
                        Text("Picked from the picture, lightest first, which is the usual print order. Click a swatch to match your ink.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Section("Garment") {
                        ColorPicker("Garment colour", selection: $garment, supportsOpacity: false)
                        Toggle("Print the garment colour too", isOn: $garmentPrints)
                            .help("Off: parts of the picture that match the garment get no ink, saving a screen")
                    }
                    Section("Blending") {
                        Slider(value: $smoothing, in: 0...1) { Text("Smooth tones") }
                        Text(smoothing < 0.01 ? "Hard: each spot gets one ink (index separation), good for flat art."
                             : "Neighbouring colours blend as halftone dots, for photos and gradients.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 340)
                Divider()
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        picture("Original", Self.cgImage(small))
                        picture("With \(inks.count) ink\(inks.count == 1 ? "" : "s")", previewImage)
                    }
                    Text("The preview mixes the inks smoothly; on the shirt they mix as halftone dots. Turn on a White underbase in Screen Print Films for dark garments.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(source.name).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Ink Layers") {
                    model.addSeparationLayers(source, inks: inks, garment: garmentInk, smoothing: smoothing)
                    dismiss()
                    // Open the films once this sheet has gone, so the two sheets don't collide.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showScreenPrint = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inks.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 880, minHeight: 560)
        .onAppear {
            garment = Color(hex: model.document.workpiece?.colorHex ?? "#FFFFFF")
            small = Self.downsample(source.image, maxSide: 360)
            pickInks()
        }
        .onChange(of: count) { _ in pickInks() }
        .onChange(of: garmentPrints) { _ in pickInks() }
    }

    private var garmentInk: InkColor? { garmentPrints ? nil : InkColor(hex: garment.hexString) }

    private func pickInks() {
        inks = PhotoSeparation.palette(source.image, count: count, garment: garmentInk)
    }

    private func inkBinding(_ k: Int) -> Binding<Color> {
        Binding(get: { inks.indices.contains(k) ? Color(hex: inks[k].hex) : .black },
                set: { if inks.indices.contains(k) { inks[k] = InkColor(hex: $0.hexString) } })
    }

    private var previewImage: CGImage? {
        guard let small else { return nil }
        let rgba = PhotoSeparation.preview(small, inks: inks, garment: garmentInk ?? InkColor(hex: garment.hexString),
                                           smoothing: smoothing)
        return Self.cgImage(ColorImage(width: small.width, height: small.height, rgba: rgba))
    }

    private func picture(_ title: String, _ image: CGImage?) -> some View {
        VStack {
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(garment)
            .border(.separator)
            Text(title).font(.caption)
        }
    }

    static func downsample(_ img: ColorImage, maxSide: Int) -> ColorImage {
        let scale = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        guard scale < 1 else { return img }
        let w = max(1, Int(Double(img.width) * scale)), h = max(1, Int(Double(img.height) * scale))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            let sy = min(img.height - 1, Int(Double(y) / scale))
            for x in 0..<w {
                let sx = min(img.width - 1, Int(Double(x) / scale))
                let s = (sy * img.width + sx) * 4, d = (y * w + x) * 4
                for c in 0..<4 { out[d + c] = img.rgba[s + c] }
            }
        }
        return ColorImage(width: w, height: h, rgba: out)
    }

    static func cgImage(_ img: ColorImage?) -> CGImage? {
        guard let img, let provider = CGDataProvider(data: Data(img.rgba) as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
