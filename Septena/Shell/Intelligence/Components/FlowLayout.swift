import SwiftUI

struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let sizes = measure(subviews: subviews, maxWidth: proposal.width)
    return layout(sizes: sizes, proposal: proposal).size
  }

  func placeSubviews(in bounds: CGRect,
                     proposal: ProposedViewSize,
                     subviews: Subviews,
                     cache: inout ()) {
    let sizes = measure(subviews: subviews, maxWidth: bounds.width)
    let offsets = layout(sizes: sizes,
                         proposal: ProposedViewSize(width: bounds.width, height: nil)).offsets

    for ((offset, size), subview) in zip(zip(offsets, sizes), subviews) {
      subview.place(
        at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y),
        proposal: ProposedViewSize(width: min(size.width, bounds.width), height: size.height)
      )
    }
  }

  /// Measure each child at its ideal size unless it exceeds `maxWidth`, in
  /// which case re-measure constrained to `maxWidth` so wrapping labels stay
  /// inside the container instead of overflowing off-screen.
  private func measure(subviews: Subviews, maxWidth: CGFloat?) -> [CGSize] {
    subviews.map { subview in
      let ideal = subview.sizeThatFits(.unspecified)
      if let maxWidth, maxWidth > 0, ideal.width > maxWidth {
        return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
      }
      return ideal
    }
  }

  private func layout(sizes: [CGSize], proposal: ProposedViewSize) -> (offsets: [CGPoint], size: CGSize) {
    guard let containerWidth = proposal.width else {
      return (sizes.map { _ in .zero }, .zero)
    }

    var offsets: [CGPoint] = []
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var maxY: CGFloat = 0
    var rowHeight: CGFloat = 0

    for size in sizes {
      if currentX > 0 && currentX + size.width > containerWidth {
        currentX = 0
        currentY += rowHeight + spacing
        rowHeight = 0
      }

      offsets.append(CGPoint(x: currentX, y: currentY))
      currentX += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      maxY = max(maxY, currentY + rowHeight)
    }

    return (offsets, CGSize(width: containerWidth, height: maxY))
  }
}
