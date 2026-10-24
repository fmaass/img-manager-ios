import Foundation
import ImgManagerAPI

/// IMGMGR-382, reshaped by IMGMGR-543 (R3-10): the loupe's look — a display aid the SERVER
/// renders, previewed on ONE photograph at a time.
///
/// A look belongs to a photograph: the Looks strip opens a `Draft` for the focused photograph,
/// and `activeLook(for:)` answers for that photograph only, so the next photograph opens unlooked
/// by construction. Any focus change, closing the loupe or opening Compare cancels the draft
/// (`GridStore.focusedImageID`'s observer). Apply is inert until P16b.
///
/// What it is not, by construction:
/// - not persisted: the chosen look and its strength live in `draft` only. The one thing kept on
///   the device is the reader's FAVOURITE look ids (`LookFavourites`);
/// - not library state: nothing here reaches a mark, a tag, a sync or any write. The only
///   requests that ever carry a look id are `GET /api/looks` and the looked proxy, which
///   `LookLeakTests` pins on the wire;
/// - not a colour table: the app neither bundles nor downloads a LUT, so there is no Core Image
///   path — only the server's looked proxy.
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
  /// The strip's state for ONE photograph: the previewed look (nil = None) and its strength.
  struct Draft: Equatable, Sendable {
    let imageID: Int
    var lookID: String?
    var strength: Int
  }

  /// What a photograph is rendered through right now.
  struct Active: Equatable, Sendable {
    let lookID: String
    let strength: Int
  }

  enum Step: Sendable {
    case previous
    case next
  }

  /// Non-nil exactly while the Looks strip is open, for `draft.imageID`.
  private(set) var draft: Draft?
  /// Bumped on every open and cancel, so a tile render that finishes after the strip it was
  /// asked for has gone never lands in the next one (`GridStore.lookTile`).
  private(set) var stripSession = 0
  /// The photographs the active draft could not be rendered for (404, 422, transport), each of
  /// which the loupe showed unlooked instead. Cleared whenever the look or strength changes.
  private(set) var unavailableImageIDs: Set<Int> = []
  let favourites: LookFavourites

  private let fetchCatalogue: @Sendable () async throws -> [Look]

  init(
    fetchCatalogue: @escaping @Sendable () async throws -> [Look],
    favourites: LookFavourites
  ) {
    self.fetchCatalogue = fetchCatalogue
    self.favourites = favourites
  }

  /// The look `imageID` is rendered through: the draft's, and only for the draft's photograph.
  func activeLook(for imageID: Int?) -> Active? {
    guard let imageID, let draft, draft.imageID == imageID, let lookID = draft.lookID else {
      return nil
    }
    return Active(lookID: lookID, strength: draft.strength)
  }

  func isStripOpen(for imageID: Int?) -> Bool {
    guard let imageID else { return false }
    return draft?.imageID == imageID
  }

  /// The control is offered only when there is something to choose.
  var canChoose: Bool { !catalogue.isEmpty }

  /// The order ←/→ walk in the strip.
  var stripOrder: [String?] {
    LookStripSections.order(catalogue: catalogue, favourites: favourites.ids)
  }

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

  /// Opens the strip on `imageID` at None and the standard strength. Already open there: no-op.
  func openStrip(imageID: Int) {
    guard canChoose, draft?.imageID != imageID else { return }
    draft = Draft(imageID: imageID, lookID: nil, strength: LookStrength.standard)
    stripSession += 1
    unavailableImageIDs = []
  }

  /// Cancel: the strip closes and the photograph is unlooked again. Nothing is remembered.
  func cancel() {
    guard draft != nil else { return }
    draft = nil
    stripSession += 1
    unavailableImageIDs = []
  }

  /// P16a: Apply is present but inert — no request, no keyword, no state change (P16b).
  func apply() {}

  /// The focused photograph changed: a draft for another photograph is cancelled.
  func focusDidChange(to imageID: Int?) {
    guard let draft, draft.imageID != imageID else { return }
    cancel()
  }

  /// Preview a look, or None with `nil`, in the open strip. An id the catalogue does not hold is
  /// refused: the previewed look is always one the reader could have picked.
  func select(_ lookID: String?) {
    guard var next = draft else { return }
    if let lookID, !catalogue.contains(where: { $0.id == lookID }) { return }
    guard next.lookID != lookID else { return }
    next.lookID = lookID
    draft = next
    unavailableImageIDs = []
  }

  /// Sets the strength, clamped to 0…200 (`LookStrength.clamped`, the one clamp).
  func setStrength(_ value: Int) {
    guard var next = draft else { return }
    let strength = LookStrength.clamped(value)
    guard next.strength != strength else { return }
    next.strength = strength
    draft = next
    unavailableImageIDs = []
  }

  /// ↑/↓: ±10 through `setStrength`. With None there is no strength to change.
  func nudgeStrength(by delta: Int) {
    guard let draft, draft.lookID != nil else { return }
    setStrength(draft.strength + delta)
  }

  /// ←/→: the previous or next tile, stopping at either end.
  func step(_ direction: Step) {
    guard let draft else { return }
    let order = stripOrder
    let index = order.firstIndex(of: draft.lookID) ?? 0
    let target = direction == .next ? index + 1 : index - 1
    guard order.indices.contains(target) else { return }
    select(order[target])
  }

  /// How the loupe's last render of `imageID` went. A report for a look or strength that is no
  /// longer the draft's (the reader moved on while the request was on the wire) is dropped.
  func recordRender(imageID: Int, lookID: String, strength: Int, available: Bool) {
    guard activeLook(for: imageID) == Active(lookID: lookID, strength: strength) else { return }
    if available {
      unavailableImageIDs.remove(imageID)
    } else {
      unavailableImageIDs.insert(imageID)
    }
  }

  /// The Looks control's spoken value: "Off", the look's name, or the name plus the fact that
  /// this photograph is being shown without it.
  func accessibilityValue(focusedImageID: Int?) -> String {
    guard let active = activeLook(for: focusedImageID) else { return "Off" }
    let lookName = name(of: active.lookID)
    if let focusedImageID, unavailableImageIDs.contains(focusedImageID) {
      return "\(lookName), unavailable for this photo"
    }
    return lookName
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
