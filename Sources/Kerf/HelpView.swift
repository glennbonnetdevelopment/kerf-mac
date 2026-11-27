import KerfCore
import SwiftUI

/// Help › KerfKutter Help: a searchable list of topics, with the chosen topic on the right.
struct HelpView: View {
    @State private var selection: String? = HelpLibrary.topics.first?.id
    @State private var query = ""

    private var results: [HelpTopic] { HelpLibrary.search(query) }

    var body: some View {
        NavigationSplitView {
            List(results, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.symbol)
                    .tag(topic.id)
            }
            .overlay {
                if results.isEmpty {
                    Text("No topics match \"\(query)\".")
                        .foregroundStyle(.secondary)
                        .padding()
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            if let id = selection, let topic = HelpLibrary.topic(id) {
                HelpTopicView(topic: topic)
                    .id(topic.id)
            } else {
                Text("Choose a topic.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search help")
        .onChange(of: query) {
            // Keep a topic showing that matches the search.
            if let id = selection, results.contains(where: { $0.id == id }) { return }
            selection = results.first?.id
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label(topic.title, systemImage: topic.symbol)
                    .font(.largeTitle.bold())
                Text(topic.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Divider()
                ForEach(Array(topic.blocks.enumerated()), id: \.offset) { _, block in
                    HelpBlockView(block: block)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: 680, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(topic.title)
    }
}

private struct HelpBlockView: View {
    let block: HelpBlock

    var body: some View {
        switch block {
        case .heading(let s):
            Text(rich(s)).font(.title2.bold()).padding(.top, 6)
        case .text(let s):
            paragraph(s)
        case .steps(let list):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.offset) { i, s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        paragraph(s)
                    }
                }
            }
        case .bullets(let list):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, s in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        paragraph(s)
                    }
                }
            }
        case .tip(let s):
            callout(s, symbol: "lightbulb", tint: .accentColor)
        case .warning(let s):
            callout(s, symbol: "exclamationmark.triangle.fill", tint: .orange)
        case .keys(let list):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(list.enumerated()), id: \.offset) { _, key in
                    GridRow {
                        Text(key.keys)
                            .font(.body.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        Text(rich(key.action))
                    }
                }
            }
        }
    }

    private func paragraph(_ s: String) -> some View {
        Text(rich(s)).fixedSize(horizontal: false, vertical: true)
    }

    private func callout(_ s: String, symbol: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            paragraph(s)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func rich(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

/// The Help menu item that opens the help window.
struct OpenHelpButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("KerfKutter Help") { openWindow(id: "help") }
            .keyboardShortcut("?", modifiers: .command)
    }
}
