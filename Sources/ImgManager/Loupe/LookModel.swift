import Foundation
import ImgManagerAPI

/// IMGMGR-382: the loupe's look — a display aid the SERVER renders, chosen for this app session
/// only.
///
/// What it is not, by construction:
/// - not persisted: no `UserDefaults`, no `@AppStorage`, no `SceneStorage`, no file. The one
///   instance lives on `GridStore`, so it survives stepping from frame to frame inside the loupe
///   (culling compares many frames under one look) and is gone on relaunch;
/// - not library state: nothing here reaches a mark, a tag, a sync or any write. The only
///   requests that ever carry a look id are `GET /api/looks` and the looked proxy
///   (`GridStore.loupePreview`), which `LookLeakTests` pins on the wire;
/// - not a colour table: the app neither bundles nor downloads a LUT (the assets' licences are
///   unresolved server-side), so there is no Core Image path — only the server's looked proxy.
///
/// The catalogue is fetched lazily, once per session, the first time a loupe opens. A failed
/// fetch leaves it empty (the Looks control is then disabled) and the next open asks again.
@Observable
@MainActor
final class LookModel {
  typealias Look = Components.Schemas.LookSummary

  enum CatalogueState: Equatable, Sendable {
    case notLoaded
    case loading
    case loaded
    case failed
  }

  /// The server's looks, in its own manifest order.
  private(set) var catalogue: [Look] = []
  private(set) var catalogueState: CatalogueState = .notLoaded
  /// The chosen look, or nil for None. Only ever an id the catalogue holds.
  private(set) var activeLookID: String?
  /// The photographs the ACTIVE look could not be rendered for (404, 422, transport), each of
  /// which the loupe showed unlooked instead. Cleared whenever the look changes.
  private(set) var unavailableImageIDs: Set<Int> = []

  private let fetchCatalogue: @Sendable () async throws -> [Look]

  init(fetchCatalogue: @escaping @Sendable () async throws -> [Look]) {
    self.fetchCatalogue = fetchCatalogue
  }

  var activeLook: Look? {
    guard let activeLookID else { return nil }
    return catalogue.first { $0.id == activeLookID }
  }

  var isActive: Bool { activeLookID != nil }

  /// The control is offered only when there is something to choose.
  var canChoose: Bool { !catalogue.isEmpty }

  /// Fetches the catalogue unless it is already loaded or on the wire. The state flips to
  /// `.loading` before the await, so a second caller arriving while the first is in flight is a
  /// no-op rather than a second request.
  func loadCatalogueIfNeeded() async {
    switch catalogueState {
    case .loading, .loaded:
      return
    case .notLoaded, .failed:
      break
    }
    catalogueState = .loading
    do {
      catalogue = try await fetchCatalogue()
      catalogueState = .loaded
    } catch {
      catalogue = []
      catalogueState = .failed
    }
  }

  /// Choose a look, or None with `nil`. An id the catalogue does not hold is refused: the active
  /// look is always one the reader could have picked.
  func select(_ lookID: String?) {
    if let lookID, !catalogue.contains(where: { $0.id == lookID }) { return }
    guard activeLookID != lookID else { return }
    activeLookID = lookID
    unavailableImageIDs = []
  }

  /// How the loupe's last render of `imageID` under `lookID` went. A report for a look that is no
  /// longer active (the reader switched while the request was on the wire) is dropped.
  func recordRender(imageID: Int, lookID: String, available: Bool) {
    guard lookID == activeLookID else { return }
    if available {
      unavailableImageIDs.remove(imageID)
    } else {
      unavailableImageIDs.insert(imageID)
    }
  }

  /// The Looks control's spoken value: "Off", the look's name, or the name plus the fact that
  /// this photograph is being shown without it.
  func accessibilityValue(focusedImageID: Int?) -> String {
    guard let look = activeLook else { return "Off" }
    if let focusedImageID, unavailableImageIDs.contains(focusedImageID) {
      return "\(look.name), unavailable for this photo"
    }
    return look.name
  }

  /// The loupe image's spoken label: what the painted photograph is being shown as.
  /// "Photograph" unlooked, "Photograph, look <name>" through a look, "Photograph, without <name>"
  /// when the chosen look could not be rendered for it — and "Photograph not loaded" while
  /// nothing is painted, so "Photograph" always means unlooked bytes are on screen.
  func imageAccessibilityLabel(for rendering: LoupeRendering?) -> String {
    switch rendering {
    case .none:
      return "Photograph not loaded"
    case .unlooked:
      return "Photograph"
    case .looked(let lookID):
      return "Photograph, look \(name(of: lookID))"
    case .fallback(let lookID):
      return "Photograph, without \(name(of: lookID))"
    }
  }

  private func name(of lookID: String) -> String {
    catalogue.first { $0.id == lookID }?.name ?? lookID
  }
}
