import ImgManagerAPI
import SwiftUI

/// IMGMGR-543 (R3-9): the loupe title's subtitle — "Master · ★★★★☆ · ● Red". The fidelity label
/// always; then Lightroom's rating and colour label when its sidecar carries them. Display-only,
/// read from `ImageSummary.lightroom` (never merged with the app's own marks).
struct LoupeSubtitle: Equatable, Sendable {
  let fidelity: String
  /// 1…5, or nil when there is no rating to show (no sidecar, unrated 0, rejected −1).
  let rating: Int?
  /// The colour label's name, or nil.
  let label: String?

  static func parts(
    sourceKind: String?, lightroom: Components.Schemas.LightroomMeta?
  ) -> LoupeSubtitle {
    let fidelity = LoupeFidelityLabel.label(sourceKind: sourceKind)
    guard let lightroom, lightroom.sidecarPresent else {
      return LoupeSubtitle(fidelity: fidelity, rating: nil, label: nil)
    }
    let rating = lightroom.rating.flatMap { (1...5).contains($0) ? $0 : nil }
    let label = lightroom.label.flatMap { text -> String? in
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty ? nil : trimmed
    }
    return LoupeSubtitle(fidelity: fidelity, rating: rating, label: label)
  }

  /// "★★★★☆".
  static func stars(_ rating: Int) -> String {
    String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating)
  }

  /// The label dot's colour: Lightroom's five named labels, anything else secondary.
  static func dotColor(_ label: String) -> Color {
    switch label.lowercased() {
    case "red": .red
    case "yellow": .yellow
    case "green": .green
    case "blue": .blue
    case "purple": .purple
    default: .secondary
    }
  }
}

/// The subtitle as separate elements joined by " · ", so `loupeFidelityLabel` keeps its exact
/// text and identifier.
struct LoupeSubtitleView: View {
  let parts: LoupeSubtitle

  var body: some View {
    HStack(spacing: 0) {
      Text(parts.fidelity)
        .accessibilityIdentifier("loupeFidelityLabel")
      if let rating = parts.rating {
        Text(" · ").accessibilityHidden(true)
        Text(LoupeSubtitle.stars(rating))
          .accessibilityLabel("\(rating) \(rating == 1 ? "star" : "stars")")
          .accessibilityIdentifier("loupeSubtitleRating")
      }
      if let label = parts.label {
        Text(" · ").accessibilityHidden(true)
        HStack(spacing: 3) {
          Text("●").foregroundStyle(LoupeSubtitle.dotColor(label))
          Text(label)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) label")
        .accessibilityIdentifier("loupeSubtitleLabel")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }
}
