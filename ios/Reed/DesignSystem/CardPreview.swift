import SwiftUI
import ReedDomain

struct CardPreview: View {
    let card: CardSummary
    var compact = false
    let open: () -> Void
    let favorite: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: open) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(card.title).reedFont(.cardTitle).lineLimit(2)
                            Spacer(minLength: 0)
                            Text(card.createdAt, format: .dateTime.day().month().year())
                                .reedFont(.metadata).foregroundStyle(ReedTheme.tertiary)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        if let source = card.source {
                            Text(source).reedFont(.metadata).foregroundStyle(ReedTheme.secondary).lineLimit(2)
                        }
                        Text(card.preview).reedFont(.body).lineSpacing(3).lineLimit(compact ? 2 : 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                HStack {
                    Button("Развернуть", action: open).reedFont(.caption).foregroundStyle(ReedTheme.secondary)
                    Spacer()
                    Button(action: favorite) { Image(systemName: card.isFavorite ? "star.fill" : "star") }
                        .accessibilityLabel(card.isFavorite ? "Убрать из избранного" : "В избранное")
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .padding(12.8)
            .overlay(RoundedRectangle(cornerRadius: ReedTheme.radius).stroke(ReedTheme.foreground, lineWidth: ReedTheme.border))
            if !compact && !card.tags.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(card.tags) { tag in TagChip(title: tag.name) }
                }.padding(.horizontal, 12)
            }
        }.foregroundStyle(ReedTheme.foreground)
    }
}

struct TagChip: View {
    let title: String
    var selected = false
    var body: some View {
        Text(title).reedFont(.caption).padding(.horizontal, 12).padding(.vertical, 4)
            .foregroundStyle(selected ? ReedTheme.background : ReedTheme.secondary)
            .background(selected ? ReedTheme.foreground : .clear, in: RoundedRectangle(cornerRadius: ReedTheme.radius))
            .overlay(RoundedRectangle(cornerRadius: ReedTheme.radius).stroke(ReedTheme.secondary, lineWidth: ReedTheme.border))
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 320, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            let frame = arrangement.frames[index]
            view.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            frames.append(CGRect(x: x, y: y, width: min(size.width, width), height: size.height))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}
