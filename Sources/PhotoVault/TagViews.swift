import SwiftUI
import PhotoVaultCore

/// Lays its views out left to right, wrapping onto new lines — tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += row + spacing
                row = 0
            }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: width.isFinite ? width : widest, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += row + spacing
                row = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// A tag or group in the filter panel: off, included (+), or excluded (−,
/// struck through). The +/− slot is always there, so a chip is the same width
/// in every state and never shifts under the pointer between two clicks.
struct RuleChip: View {
    let label: String
    var count: Int?
    let state: TagRules.State?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: state == .exclude ? "minus" : "plus")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 10)
                    .opacity(state == nil ? 0 : 1)
                Text(label)
                    .strikethrough(state == .exclude)
                    .lineLimit(1)
                if let count {
                    Text("\(count)").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.vertical, 3)
            .padding(.leading, 5)
            .padding(.trailing, 9)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
            .foregroundStyle(foreground)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(state == nil ? "Click to include" : state == .include ? "Included — click to exclude" : "Excluded — click to clear")
    }

    private var fill: Color {
        switch state {
        case .include: return .green.opacity(0.18)
        case .exclude: return .red.opacity(0.15)
        case nil: return .clear
        }
    }

    private var stroke: Color {
        switch state {
        case .include: return .green.opacity(0.7)
        case .exclude: return .red.opacity(0.7)
        case nil: return .secondary.opacity(0.5)
        }
    }

    private var foreground: Color {
        switch state {
        case .include: return .green
        case .exclude: return .red
        case nil: return .primary
        }
    }
}
