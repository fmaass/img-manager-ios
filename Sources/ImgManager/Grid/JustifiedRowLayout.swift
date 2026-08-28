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

/// One tile's FINAL resolved plan after row-level tier choice and never-upscale reflow/cap
/// (diff-gate blocker 2, round 2: "reflow/cap the ROW not individual tiles"; "tier-select from
/// the actual rendered edge").
struct PackedTilePlan: Equatable {
  var imageID: Int
  var plan: TileRenderPlan
}

extension JustifiedRowLayout {
  /// The one function GridView actually renders from: packs justified rows (`pack`, above),
  /// then for EACH row — not each tile independently — chooses each tile's proxy tier from its
  /// own natural (pre-cap) packed size, queries availability, and if ANY available tile in the
  /// row needs more pixels than its tier actually has, caps the WHOLE ROW down by the same
  /// factor (never per-tile), so every tile in a row stays the same height, matching a real
  /// justified grid. A tile whose chosen tier is genuinely unavailable (pending/failed/missing)
  /// renders a placeholder at its natural size and does not participate in the row's cap
  /// computation (nothing to never-upscale there — there are no pixels to compare against).
  static func packWithTierPlan(
    tiles: [JustifiedTile],
    paneWidth: CGFloat,
    targetRowHeight: CGFloat,
    displayScale: CGFloat,
    spacing: CGFloat = 2,
    availability: (Int, ProxyTier) -> ProxyAvailability
  ) -> [[PackedTilePlan]] {
    let naturalRows = pack(
      tiles: tiles, paneWidth: paneWidth, targetRowHeight: targetRowHeight, spacing: spacing)

    return naturalRows.map { row in
      // Pass 1: tier per tile from its NATURAL (pre-cap) size — the actual rendered edge
      // justification computed, never a nominal row-height guess.
      struct Resolved {
        var imageID: Int
        var naturalSize: CGSize
        var tier: ProxyTier
        var availability: ProxyAvailability
      }
      let resolved = row.map { tile -> Resolved in
        let tier = GridTierResolver.chooseTier(for: tile.size, displayScale: displayScale)
        return Resolved(
          imageID: tile.imageID, naturalSize: tile.size, tier: tier,
          availability: availability(tile.imageID, tier))
      }

      // Pass 2: the ROW's cap scale — the smallest ratio (available pixels / required pixels)
      // across every tile in the row whose tier IS available; 1.0 (no cap) if none constrain it.
      let ratios: [Double] = resolved.compactMap { item in
        guard case .ok(let w, let h) = item.availability else { return nil }
        let required = GridTierResolver.requiredPixels(
          for: item.naturalSize, displayScale: displayScale)
        guard required > 0 else { return nil }
        let availableLongEdge = Double(max(w, h))
        return min(1.0, availableLongEdge / required)
      }
      let rowCapScale = CGFloat(ratios.min() ?? 1.0)

      // Pass 3: build the final plan per tile — capped tiles keep the SAME scale as their row
      // siblings (uniform row height preserved), never an independent per-tile shrink.
      return resolved.map { item -> PackedTilePlan in
        switch item.availability {
        case .pending:
          return PackedTilePlan(imageID: item.imageID, plan: .placeholder(reason: .pending))
        case .permanentFail:
          return PackedTilePlan(imageID: item.imageID, plan: .placeholder(reason: .permanentFail))
        case .missing:
          return PackedTilePlan(imageID: item.imageID, plan: .placeholder(reason: .missing))
        case .ok:
          let finalSize = CGSize(
            width: item.naturalSize.width * rowCapScale,
            height: item.naturalSize.height * rowCapScale)
          return PackedTilePlan(
            imageID: item.imageID, plan: .display(tier: item.tier, size: finalSize))
        }
      }
    }
  }
}
