import Foundation
import ImgManagerAPI

/// IMGMGR-543 (R3-10): a look's strength, in percent — 0 is the unlooked proxy, 100 the look as
/// authored, 200 doubles it (the server clips). The ONE clamp lives here.
enum LookStrength {
  static let range = 0...200
  static let standard = 100
  static let nudge = 10
  static let detents = [0, 100, 200]
  /// How close a released slider must be to a detent to land on it.
  static let detentPull = 8

  static func clamped(_ value: Int) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
  }

  /// A released slider's value: a detent when within its pull, else the nearest step of 10.
  static func snapped(_ raw: Double) -> Int {
    let value = clamped(Int(raw.rounded()))
    if let detent = detents.first(where: { abs($0 - value) <= detentPull }) { return detent }
    return clamped(Int((Double(value) / Double(nudge)).rounded()) * nudge)
  }

  /// "120 %".
  static func label(_ strength: Int) -> String { "\(strength) %" }
}

/// The strip's sections (R3-10: None, Favourites, Film · Camera · Mono), built from the server's
/// free-text categories. A favourite is shown in Favourites ONLY, so every look id appears once
/// and ←/→ walk one list.
enum LookStripSections {
  typealias Look = Components.Schemas.LookSummary

  enum Group: String, CaseIterable, Sendable {
    case favourites, film, camera, mono, other

    var title: String {
      switch self {
      case .favourites: "Favourites"
      case .film: "Film"
      case .camera: "Camera"
      case .mono: "Mono"
      case .other: "Other"
      }
    }
  }

  struct Section: Equatable, Sendable {
    let group: Group
    let looks: [Look]
  }

  /// Black and white first (a mono camera look is Mono), then camera, then film; anything else
  /// is Other.
  static func group(ofCategory category: String) -> Group {
    let text = category.lowercased()
    if text.contains("black and white") || text.contains("mono") { return .mono }
    if text.contains("camera") { return .camera }
    if text.hasPrefix("film") { return .film }
    return .other
  }

  /// Non-empty sections in strip order; each keeps the server's manifest order.
  static func sections(catalogue: [Look], favourites: [String]) -> [Section] {
    let favourite = Set(favourites)
    var result: [Section] = []
    let favoured = catalogue.filter { favourite.contains($0.id) }
    if !favoured.isEmpty { result.append(Section(group: .favourites, looks: favoured)) }
    for group in [Group.film, .camera, .mono, .other] {
      let looks = catalogue.filter {
        !favourite.contains($0.id) && Self.group(ofCategory: $0.category) == group
      }
      if !looks.isEmpty { result.append(Section(group: group, looks: looks)) }
    }
    return result
  }

  /// The order ←/→ walk: None, then every look as the sections draw it.
  static func order(catalogue: [Look], favourites: [String]) -> [String?] {
    [nil] + sections(catalogue: catalogue, favourites: favourites).flatMap { $0.looks.map(\.id) }
  }
}

/// The reader's favourite looks, kept on this device only — look ids, never a chosen look or a
/// strength. Its own key, outside `GridPreferences.persistedKeys`.
@Observable
@MainActor
final class LookFavourites {
  static let key = "loupe.looks.favourites"

  private(set) var ids: [String]
  @ObservationIgnored private let defaults: UserDefaults

  init(defaults: UserDefaults) {
    self.defaults = defaults
    ids = defaults.stringArray(forKey: Self.key) ?? []
  }

  func contains(_ id: String) -> Bool { ids.contains(id) }

  func toggle(_ id: String) {
    if let index = ids.firstIndex(of: id) {
      ids.remove(at: index)
    } else {
      ids.append(id)
    }
    defaults.set(ids, forKey: Self.key)
  }
}

/// IMGMGR-544 (P16b): the SAVED-look rule — grid tiles, the tile glyph, share, and the loupe when
/// no strip is open all read a photograph's look through here, never through a draft. A Lightroom
/// edit supersedes a saved look: the photograph renders as the edit, so the pencil and a look can
/// never be drawn together.
enum LookPersistence {
  /// What a photograph renders through by its saved state: nil when nothing is saved, or when an
  /// edit (`hasEdit == true`) supersedes the saved look.
  static func savedRender(
    look: Components.Schemas.ImageLookView?, hasEdit: Bool?
  ) -> LookModel.Active? {
    guard let look, hasEdit != true else { return nil }
    return LookModel.Active(lookID: look.lookId, strength: LookStrength.clamped(look.strength))
  }

  /// A look is saved, and an edit renders instead of it.
  static func isSuperseded(look: Components.Schemas.ImageLookView?, hasEdit: Bool?) -> Bool {
    look != nil && hasEdit == true
  }

  /// The loupe chip: "Portra 400 · 120 %", or "Portra 400 · superseded by edit". Nil without a
  /// saved look. `lookName` is the catalogue's name; the id stands in when it has none.
  static func chipText(
    look: Components.Schemas.ImageLookView?, hasEdit: Bool?, lookName: String?
  ) -> String? {
    guard let look else { return nil }
    let name = lookName ?? look.lookId
    if isSuperseded(look: look, hasEdit: hasEdit) { return "\(name) · superseded by edit" }
    return "\(name) · \(LookStrength.label(LookStrength.clamped(look.strength)))"
  }
}
