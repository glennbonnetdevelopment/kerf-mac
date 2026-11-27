import SwiftUI

/// Marks a toolbar separator, so the flow layout can hide it at the start or end of a row.
struct ToolbarSeparatorKey: LayoutValueKey {
    static let defaultValue = false
}

/// Lays toolbar items out left to right and wraps onto more rows when the window is too narrow,
/// so every tool stays reachable. Items between separators are kept together on one row when
/// they fit, and separators that would sit at the start or end of a row are hidden.
struct ToolbarFlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 4

    struct Placement {
        var index: Int
        var origin: CGPoint
        var size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let (_, size) = arrange(maxWidth: maxWidth ?? .infinity, subviews: subviews)
        return CGSize(width: maxWidth ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (placements, _) = arrange(maxWidth: bounds.width, subviews: subviews)
        var placed = Set<Int>()
        for p in placements {
            placed.insert(p.index)
            subviews[p.index].place(at: CGPoint(x: bounds.minX + p.origin.x, y: bounds.minY + p.origin.y),
                                    proposal: ProposedViewSize(p.size))
        }
        // Hidden separators and empty spacers get no room.
        for i in subviews.indices where !placed.contains(i) {
            subviews[i].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
        }
    }

    /// Positions for the visible items, and the size they need.
    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> ([Placement], CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let isSeparator = subviews.indices.map { i in
            subviews[i][ToolbarSeparatorKey.self] || (sizes[i].width <= 1.5 && sizes[i].height > 4)
        }

        // Groups of items, each starting with the separator before it (if any).
        // Items with no size, such as spacers, are left out.
        var groups: [(separator: Int?, items: [Int])] = [(nil, [])]
        for i in subviews.indices {
            if isSeparator[i] {
                groups.append((i, []))
            } else if sizes[i].width > 0.5 {
                groups[groups.count - 1].items.append(i)
            }
        }
        groups.removeAll { $0.items.isEmpty }

        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0
        var rowIsEmpty: Bool { rows[rows.count - 1].isEmpty }
        func width(of items: [Int]) -> CGFloat {
            items.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(max(0, items.count - 1))
        }
        func startRow() {
            if !rowIsEmpty { rows.append([]) }
            rowWidth = 0
        }
        func append(_ i: Int) {
            rowWidth += (rowIsEmpty ? 0 : spacing) + sizes[i].width
            rows[rows.count - 1].append(i)
        }

        for group in groups {
            let itemsWidth = width(of: group.items)
            let separatorWidth = group.separator.map { sizes[$0].width + spacing } ?? 0
            if !rowIsEmpty {
                if rowWidth + spacing + separatorWidth + itemsWidth <= maxWidth {
                    // The whole group fits on this row.
                    if let s = group.separator { append(s) }
                    group.items.forEach(append)
                    continue
                }
                // Move the group to a new row, unless it is too wide for any row anyway.
                if itemsWidth <= maxWidth { startRow() } else if let s = group.separator { append(s) }
            }
            for i in group.items {
                if !rowIsEmpty, rowWidth + spacing + sizes[i].width > maxWidth { startRow() }
                append(i)
            }
        }
        // No separator at the end of a row.
        for r in rows.indices {
            while let last = rows[r].last, isSeparator[last] { rows[r].removeLast() }
        }
        rows.removeAll { $0.isEmpty }

        var placements: [Placement] = []
        var y: CGFloat = 0
        var widest: CGFloat = 0
        for row in rows {
            let height = row.filter { !isSeparator[$0] }.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for i in row {
                // A separator is never taller than its row.
                let size = isSeparator[i] ? CGSize(width: sizes[i].width, height: min(sizes[i].height, height)) : sizes[i]
                placements.append(Placement(index: i, origin: CGPoint(x: x, y: y + (height - size.height) / 2), size: size))
                x += size.width + spacing
            }
            widest = max(widest, x - spacing)
            y += height + rowSpacing
        }
        return (placements, CGSize(width: widest, height: max(0, y - rowSpacing)))
    }
}

/// A thin vertical line between toolbar groups. SwiftUI's own divider draws horizontally outside a
/// stack, so the editor toolbar uses this one inside its flow layout.
struct ToolbarSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .layoutValue(key: ToolbarSeparatorKey.self, value: true)
    }
}
