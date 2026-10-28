import Foundation
import ImgManagerAPI

/// IMGMGR-382, reshaped by IMGMGR-543 (R3-10): the loupe's look — a display aid the SERVER
/// renders, previewed on ONE photograph at a time.
///
/// A look belongs to a photograph: the Looks strip opens a `Draft` for the focused photograph,
/// and `activeLook(for:)` answers for that photograph only, so the next photograph opens unlooked
/// by construction. Any focus change, closing the loupe or opening Compare cancels the draft
/// (`GridStore.focusedImageID`'s observer).
///
/// IMGMGR-544 (P16b): Apply SAVES the draft on the server (`GridStore.applyLook`, PUT or DELETE
/// `/api/images/{id}/look`); the saved look then lives on the photograph's summary (`look`), not
/// here. The strip opens seeded from it, and is frozen while its save is on the wire (`saving`).
///
/// What it is not, by construction:
/// - not persisted on the device: the draft lives in `draft` only and the saved look on the
///   server only. The one thing kept on the device is the reader's FAVOURITE look ids
///   (`LookFavourites`);
/// - not a mark, a tag, a keyword or XMP: the only requests that ever carry a look id are
///   `GET /api/looks`, the looked proxy and the saved-look PUT/DELETE, which the wire pin in
///   `LookModelTests` holds;
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
    /// IMGMGR-544: bumped on every change of the look or the strength.
    var revision = 0
    /// IMGMGR-544 / IMGMGR-642: the catalogue `version` of `lookID` when the draft took that
    /// look — what the strip previewed, and what Apply sends as `look_version`. Never re-read at
    /// Apply time. Nil for None, and for a saved look the catalogue does not hold.
    var lookVersion: String?
  }

  /// What a photograph is rendered through right now.
  struct Active: Hashable, Sendable {
    let lookID: String
    let strength: Int
  }

  /// IMGMGR-544: why a save did not land, as the strip says it.
  enum SaveFailure: Equatable, Sendable {
    /// The server refused it (422): nothing was written.
    case refused
    /// The photograph is gone (404): nothing was written.
    case gone
    /// No answer: the server may or may not hold it.
    case uncertain
    /// The look changed on the server since it was previewed (409): nothing was written, and
    /// the strip's tile now shows the new version.
    case versionChanged

    init(_ error: LookWriteError) {
      switch error {
      case .refused: self = .refused
      case .gone: self = .gone
      case .uncertain: self = .uncertain
      case .versionConflict: self = .versionChanged
      }
    }

    var copy: String {
      switch self {
      case .refused: "Couldn't save the look. Try again."
      case .gone: "This photo is no longer in the library."
      case .uncertain: "Couldn't confirm the look was saved."
      case .versionChanged: "Look updated \u{2014} preview again"
      }
    }
  }

  /// A failed save, scoped to the strip session it was made in.
  struct SaveFailureNote: Equatable, Sendable {
    let imageID: Int
    let session: Int
    let reason: SaveFailure
  }

  /// IMGMGR-650: a finger on the loupe image, or `\` on a hardware keyboard. Both may hold at
  /// once; the original shows until the LAST of them lets go.
  enum OriginalHold: Hashable, Sendable {
    case touch
    case key
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
  /// IMGMGR-544: the photographs whose save is on the wire. While a photograph is here its draft
  /// is frozen (every mutator is a no-op) and Apply cannot be pressed again.
  private(set) var saving: Set<Int> = []
  /// IMGMGR-544: the last failed save. Shown only for the strip session it was made in
  /// (`visibleSaveFailure`), so a reopened draft never inherits an earlier failure.
  private(set) var saveFailure: SaveFailureNote?
  /// IMGMGR-544: per-look tile generations of the open strip, bumped when a tile is invalidated
  /// (`GridStore.invalidateLookTile`). The tile view's task id carries it, so a bump re-renders
  /// the tile; `GridStore.lookTile` drops a render that was asked for under an older one.
  private(set) var tileGeneration: [String: Int] = [:]
  /// IMGMGR-650: what holds the original on screen right now (`GridStore.holdOriginal`). Only
  /// while the strip is open: every open and cancel empties it.
  private(set) var originalHolds: Set<OriginalHold> = []
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

  /// IMGMGR-650: hold-to-original — the loupe paints the unlooked preview, labelled "Original",
  /// in place of the look while this is true.
  var showOriginal: Bool { !originalHolds.isEmpty }

  /// IMGMGR-650: a hold starts; nothing without an open strip.
  func beginOriginalHold(_ hold: OriginalHold) {
    guard draft != nil else { return }
    originalHolds.insert(hold)
  }

  /// IMGMGR-650: a hold ends — always honoured.
  func endOriginalHold(_ hold: OriginalHold) {
    originalHolds.remove(hold)
  }

  /// IMGMGR-650: every hold ends at once (the app left the foreground: a release may never come).
  func endOriginalHolds() {
    originalHolds = []
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

  /// IMGMGR-544: fetch the catalogue AGAIN, after a save found the server serving another version
  /// of a look. On success the catalogue is replaced; on failure the one already held is KEPT,
  /// so a failed re-fetch never disables an open strip. The draft is not touched.
  func refetchCatalogue() async {
    guard let fresh = try? await fetchCatalogue() else { return }
    catalogue = fresh
    catalogueState = .loaded
  }

  /// IMGMGR-544: after `refetchCatalogue`, the open draft takes the catalogue's version of its
  /// own look — the version its tile now previews — so the reader's next Apply sends it. Only for
  /// the strip session the save was made in, and only while the draft still holds `lookID`.
  /// Allowed while the draft is frozen (it runs before the save leaves `saving`); it saves
  /// nothing, and does not bump `revision`.
  func adoptCatalogueVersion(imageID: Int, session: Int, lookID: String) {
    guard var next = draft, stripSession == session else { return }
    guard next.imageID == imageID, next.lookID == lookID else { return }
    next.lookVersion = version(of: lookID)
    draft = next
  }

  /// The tile generation `lookID`'s strip tile is rendered under; 0 for None and for a look whose
  /// tile was never invalidated.
  func tileToken(for lookID: String?) -> Int {
    guard let lookID else { return 0 }
    return tileGeneration[lookID] ?? 0
  }

  /// Invalidate `lookID`'s strip tile (`GridStore.invalidateLookTile` is the caller).
  func bumpTile(_ lookID: String) {
    tileGeneration[lookID, default: 0] += 1
  }

  /// Opens the strip on `imageID`, seeded from its SAVED look (IMGMGR-544), else at None and the
  /// standard strength. Already open there: no-op.
  func openStrip(imageID: Int, saved: Components.Schemas.ImageLookView? = nil) {
    guard canChoose, draft?.imageID != imageID else { return }
    let savedVersion = version(of: saved?.lookId)
    draft = Draft(
      imageID: imageID, lookID: saved?.lookId,
      strength: saved.map { LookStrength.clamped($0.strength) } ?? LookStrength.standard,
      lookVersion: savedVersion)
    stripSession += 1
    unavailableImageIDs = []
    saveFailure = nil
    tileGeneration = [:]
    originalHolds = []
  }

  /// Cancel: the strip closes and the photograph shows its saved look (or none) again. A save
  /// already on the wire is not recalled.
  func cancel() {
    guard draft != nil else { return }
    draft = nil
    stripSession += 1
    unavailableImageIDs = []
    saveFailure = nil
    tileGeneration = [:]
    originalHolds = []
  }

  /// Whether `imageID`'s save is on the wire.
  func isSaving(_ imageID: Int?) -> Bool {
    guard let imageID else { return false }
    return saving.contains(imageID)
  }

  /// The ONE insertion into `saving` (`GridStore.applyLook`, followed at once by its `defer`).
  func beginSave(_ imageID: Int) {
    saving.insert(imageID)
    saveFailure = nil
  }

  /// The ONE removal from `saving`, run on every completion path by `GridStore.applyLook`.
  func endSave(_ imageID: Int) {
    saving.remove(imageID)
  }

  func noteSaveFailure(imageID: Int, session: Int, reason: SaveFailure) {
    saveFailure = SaveFailureNote(imageID: imageID, session: session, reason: reason)
  }

  /// The failure the open strip on `imageID` shows: only one made in THIS strip session.
  func visibleSaveFailure(for imageID: Int?) -> SaveFailure? {
    guard let note = saveFailure, note.session == stripSession, isStripOpen(for: imageID),
      note.imageID == imageID
    else { return nil }
    return note.reason
  }

  /// Whether the open draft may change: not while its save is on the wire.
  private var isDraftFrozen: Bool {
    guard let draft else { return true }
    return saving.contains(draft.imageID)
  }

  /// The focused photograph changed: a draft for another photograph is cancelled.
  func focusDidChange(to imageID: Int?) {
    guard let draft, draft.imageID != imageID else { return }
    cancel()
  }

  /// Preview a look, or None with `nil`, in the open strip. An id the catalogue does not hold is
  /// refused: the previewed look is always one the reader could have picked.
  func select(_ lookID: String?) {
    guard var next = draft, !isDraftFrozen else { return }
    if let lookID, !catalogue.contains(where: { $0.id == lookID }) { return }
    guard next.lookID != lookID else { return }
    next.lookID = lookID
    next.lookVersion = version(of: lookID)
    next.revision += 1
    draft = next
    unavailableImageIDs = []
  }

  /// Sets the strength, clamped to 0…200 (`LookStrength.clamped`, the one clamp).
  func setStrength(_ value: Int) {
    guard var next = draft, !isDraftFrozen else { return }
    let strength = LookStrength.clamped(value)
    guard next.strength != strength else { return }
    next.strength = strength
    next.revision += 1
    draft = next
    unavailableImageIDs = []
  }

  /// ↑/↓: ±10 through `setStrength`. With None there is no strength to change.
  func nudgeStrength(by delta: Int) {
    guard let draft, draft.lookID != nil, !isDraftFrozen else { return }
    setStrength(draft.strength + delta)
  }

  /// ←/→: the previous or next tile, stopping at either end.
  func step(_ direction: Step) {
    guard let draft, !isDraftFrozen else { return }
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

  /// The catalogue's `version` of `lookID`, nil for None or when the catalogue does not hold it.
  func version(of lookID: String?) -> String? {
    guard let lookID else { return nil }
    return catalogue.first { $0.id == lookID }?.version
  }

  /// The catalogue's name for `lookID`, nil when the catalogue does not hold it.
  func catalogueName(of lookID: String) -> String? {
    catalogue.first { $0.id == lookID }?.name
  }

  private func name(of lookID: String) -> String {
    catalogue.first { $0.id == lookID }?.name ?? lookID
  }
}
