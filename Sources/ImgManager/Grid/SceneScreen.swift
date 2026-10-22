import ImgManagerAPI
import SwiftUI

// WP442 P12 (IMGMGR-540): a scene card PUSHES a scene screen. The types below are the pieces of
// that screen that are pure enough to live outside `GridStore` and `GridView`.

/// What one `GridView` instance renders: the folder's stream, or ONE entered scene. An
/// instance's scope is a constant for its lifetime, so a late report from an outgoing instance
/// can only ever describe its own scope.
enum GridScope: Hashable, Sendable {
  case stream
  case scene(Int)
  /// IMGMGR-541 (R3-21): the photographs without a mark (or rating), entered like a scene.
  case remainder(GroupByKey)
}

/// What the reader has entered over the stream: a scene, or the Mark/Rating remainder. ONE stored
/// value in `GridStore` (`entry`), so the two can never both be entered (P12 §2.1 reserved this).
enum GridEntry: Equatable, Sendable {
  case scene(SceneEntry)
  case remainder(GroupByKey)
}

/// The scene the reader has entered. A struct (one field now) so P13 can add a group entry
/// without a second stored variable.
struct SceneEntry: Equatable, Sendable {
  let stackID: Int
}

/// Why the entry changed. Only `GridStore.transitionScene(to:reason:)` consumes it.
enum SceneTransitionReason: Equatable, Sendable {
  case userOpen
  case userBack
  case scopeChanged
  case shootOpened
  case retarget
  case sceneGone
  case sessionEnded
}

/// Who may navigate when a topology edit completes: the scene that was entered when the edit
/// started, at the revision it was entered at. A stream-initiated edit has `stackID == nil` and
/// therefore never navigates.
struct SceneEditOwner: Equatable, Sendable {
  let stackID: Int?
  let revision: Int
}

/// A destination candidate's membership, read straight from the server and never through the
/// single-flight members cache.
struct CandidateMembers: Sendable {
  let items: [Components.Schemas.ImageSummary]
  let cursor: SceneMemberCursor
}

/// A topology result whose destination could not be told (a candidate read failed and no
/// loaded candidate holds the anchor). Retry re-runs the destination resolution over these.
struct SceneDestinationRetry: Sendable {
  let owner: SceneEditOwner
  let candidates: [Int]
  let anchorImageID: Int
}

/// What the scene screen shows. An empty membership is never shown: it leaves the scene.
enum SceneScreenState: Equatable, Sendable {
  case loading
  case failed
  case loaded

  static func resolve(hasMembers: Bool, isInFlight: Bool, hasFailed: Bool) -> SceneScreenState {
    if hasMembers { return .loaded }
    if isInFlight { return .loading }
    return hasFailed ? .failed : .loading
  }
}

/// "Scene · 7 photos" — the count of what the card opened.
enum SceneScreenTitle {
  static func title(memberCount: Int) -> String {
    "Scene · \(memberCount) \(memberCount == 1 ? "photo" : "photos")"
  }
}

/// A store-bound presentation flag, as seen from ONE grid instance. Only the active instance
/// shows it, and only the active instance may write it: an outgoing instance's dismissal write
/// is dropped, so it can never close the presentation the active instance is showing.
enum PresentationGate {
  static func binding(_ flag: Binding<Bool>, active: Bool) -> Binding<Bool> {
    Binding(
      get: { active && flag.wrappedValue },
      set: { newValue in
        guard active else { return }
        flag.wrappedValue = newValue
      })
  }
}

/// Card focus and photo focus are mutually exclusive: a card taking real focus clears the photo
/// focus (so no mark has a target), and a photo taking focus makes the card let go. Each branch
/// writes only on a non-nil new value of the OTHER source, and what it writes is a nil.
struct SceneCardFocusBridge: ViewModifier {
  let focusedCard: FocusState<Int?>.Binding
  let store: GridStore

  func body(content: Content) -> some View {
    content
      .onChange(of: focusedCard.wrappedValue) { _, card in
        if let card { store.cardDidTakeFocus(card) }
      }
      .onChange(of: store.focusedImageID) { _, photo in
        if photo != nil { focusedCard.wrappedValue = nil }
      }
  }
}

/// Regular's Back out of a scene: "‹ <folder>", one line, truncated in the middle; it speaks the
/// FULL folder title.
struct SceneBackButton: View {
  let folderTitle: String
  let store: GridStore

  var body: some View {
    Button {
      store.leaveScene(.userBack)
    } label: {
      HStack(spacing: 2) {
        Image(systemName: "chevron.left")
        Text(folderTitle).lineLimit(1).truncationMode(.middle)
      }
      .frame(maxWidth: 260)
    }
    .accessibilityLabel(folderTitle)
    .accessibilityIdentifier("sceneBackButton")
  }
}

/// Compact: inside a scene the folder's title stays readable under "Scene · N photos" even when
/// the system shortens the Back label. Applied only inside a scene.
struct SceneFolderSubtitle: ViewModifier {
  let subtitle: String?

  func body(content: Content) -> some View {
    if let subtitle {
      content.navigationSubtitle(subtitle)
    } else {
      content
    }
  }
}
