import KerfCore
import SwiftUI

/// Browse and edit saved materials, apply them to the current layer, and share them as JSON files.
struct MaterialLibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var kind: DeviceKind = .grblLaser
    @State private var search = ""
    @State private var selectedID: UUID?

    private var shown: [Material] {
        let all = model.materials.materials(for: kind)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { ($0.title + " " + $0.notes).lowercased().contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                Picker("Machine", selection: $kind) {
                    ForEach(DeviceKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .padding(8)
                List(selection: $selectedID) {
                    ForEach(shown) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name.isEmpty ? "Untitled" : m.name)
                            Text([m.thickness > 0 ? Material.formatThickness(m.thickness) : nil, m.operation.isEmpty ? nil : m.operation, m.settings.mode.title]
                                .compactMap { $0 }.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(Optional(m.id))
                        .contextMenu {
                            Button("Duplicate") { duplicate(m) }
                            Button("Delete", role: .destructive) { delete(m.id) }
                        }
                    }
                }
                .searchable(text: $search, placement: .sidebar, prompt: "Search materials")
                .overlay {
                    if shown.isEmpty {
                        Text(search.isEmpty ? "No materials for a \(kind.title.lowercased()) yet.\nSet up a layer, then choose Material › Save these settings as a material."
                                            : "No matches.")
                            .multilineTextAlignment(.center)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let id = selectedID, let binding = materialBinding(id) {
                MaterialDetail(material: binding, delete: { delete(id) }, duplicate: { duplicate(binding.wrappedValue) })
            } else {
                Text("Select a material.").foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.importMaterials() } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .help("Add materials from a KerfKutter materials file")
                Button { model.exportMaterials() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Save every material to a file you can share or back up")
                    .disabled(model.materials.materials.isEmpty)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { kind = model.profile.kind }
        .onChange(of: kind) { _, _ in
            if let id = selectedID, model.materials.material(id)?.kind != kind { selectedID = nil }
        }
    }

    private func materialBinding(_ id: UUID) -> Binding<Material>? {
        guard model.materials.material(id) != nil else { return nil }
        return Binding(
            get: { model.materials.material(id) ?? Material(name: "", kind: kind, settings: Layer(name: "", colorHex: "#000000")) },
            set: { var m = $0; m.modified = Date(); model.materials.upsert(m) }
        )
    }

    private func duplicate(_ m: Material) {
        var copy = m
        copy.id = UUID()
        copy.name = m.name + " copy"
        copy.modified = Date()
        model.materials.upsert(copy)
        selectedID = copy.id
    }

    private func delete(_ id: UUID) {
        model.materials.remove(id)
        if selectedID == id { selectedID = nil }
    }
}

private struct MaterialDetail: View {
    @EnvironmentObject var model: AppModel
    @Binding var material: Material
    let delete: () -> Void
    let duplicate: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Material", text: $material.name)
                    LabeledContent("Thickness (mm)") {
                        TextField("", value: $material.thickness, format: .number.precision(.fractionLength(0...2))).frame(width: 80)
                    }
                    TextField("Operation", text: $material.operation, prompt: Text("Cut, Score, Engrave…"))
                    TextField("Notes", text: $material.notes, axis: .vertical).lineLimit(2...5)
                    LabeledContent("Machine", value: material.kind.title)
                }
            }
            .formStyle(.grouped)
            .frame(maxHeight: 250)
            LayerSettings(layer: $material.settings, kind: material.kind, showsIdentity: false)
            Divider()
            HStack {
                Button("Delete", role: .destructive, action: delete)
                Button("Duplicate", action: duplicate)
                Button("Export…") { model.exportMaterials([material.id]) }
                Spacer()
                if material.kind != model.profile.kind {
                    Text("For a \(material.kind.title.lowercased()); the current machine is a \(model.profile.kind.title.lowercased()).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button("Apply to current layer") {
                    if let layer = model.currentLayerID { model.applyMaterial(material.id, to: layer) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.currentLayerID == nil)
            }
            .padding(10)
        }
    }
}
