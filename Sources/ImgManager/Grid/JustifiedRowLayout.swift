import CoreGraphics

/// Pure justified-row packing for the grid ("full-bleed justified grid" — 3213 §4, adopted for
/// native at 3220 §2.2). A standard greedy justified-gallery algorithm: accumulate tiles into a
/// row until their combined natural width at the target row height would meet or exceed the
/// pane width, then rescale that row's height so its tiles fill the width EXACTLY — except a
/// trailing partial row, which keeps the target height rather than stretching to fill.
///
/// This is what both the rendered layout AND `GridStore.rows` (Up/Down navigation) are built
/// from — one packing pass feeds both, so navigation always agrees with what is actually on
/// screen.
struct JustifiedTile: Equatable {
  var imageID: Int
  var aspectRatio: Double
}

struct PackedTile: Equatable {
  var imageID: Int
  var size: CGSize
}

enum JustifiedRowLayout {
  static func pack(
    tiles: [JustifiedTile],
    paneWidth: CGFloat,
    targetRowHeight: CGFloat,
    spacing: CGFloat = 2
  ) -> [[PackedTile]] {
    guard paneWidth > 0, targetRowHeight > 0, !tiles.isEmpty else { return [] }

    var rows: [[PackedTile]] = []
    var currentRow: [JustifiedTile] = []
    var aspectSum: Double = 0

    func flush(stretchToFill: Bool) {
      guard !currentRow.isEmpty else { return }
      let spacingTotal = spacing * CGFloat(max(currentRow.count - 1, 0))
      let availableWidth = max(paneWidth - spacingTotal, 1)
      let naturalHeight =
        aspectSum > 0 ? availableWidth / CGFloat(aspectSum) : targetRowHeight
      let rowHeight = stretchToFill ? naturalHeight : min(naturalHeight, targetRowHeight)
      rows.append(
        currentRow.map {
          PackedTile(
            imageID: $0.imageID,
            size: CGSize(width: rowHeight * CGFloat($0.aspectRatio), height: rowHeight))
        })
      currentRow = []
      aspectSum = 0
    }

    for tile in tiles {
      currentRow.append(tile)
      aspectSum += tile.aspectRatio
      let spacingTotal = spacing * CGFloat(max(currentRow.count - 1, 0))
      let neededWidthAtTarget = CGFloat(aspectSum) * targetRowHeight + spacingTotal
      if neededWidthAtTarget >= paneWidth {
        flush(stretchToFill: true)
      }
    }
    // Trailing partial row: never stretched past the target height.
    flush(stretchToFill: false)
    return rows
  }
}
