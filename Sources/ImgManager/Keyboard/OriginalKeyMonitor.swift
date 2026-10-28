import Foundation
import GameController

/// IMGMGR-650: `\` HELD on a hardware keyboard shows the original (`GridStore.holdOriginal`) —
/// the one key in the app that needs its release as well as its press.
///
/// Why the GameController keyboard and not the alternatives:
/// - every other key reaches the app as a SwiftUI key binding (`AppCommands`,
///   `SilentKeyCommandHost`), and a key binding fires on the press only — it has no release;
/// - SwiftUI's `onKeyPress(_:phases:)` reports `.down` and `.up`, but only to a view that has
///   (or contains) focus. Nothing in the loupe may hold focus: the strip's controls are
///   `.focusable(false)` precisely because a focused view takes ←→↑↓ from the key commands
///   (`LooksStripView`), so a focusable host for `\` would bring that defect back;
/// - a UIKit responder's `pressesBegan`/`pressesEnded` arrive only through the first-responder
///   chain, which a view inside the SwiftUI hierarchy is not on unless it takes first responder
///   — the same theft.
///
/// `GCKeyboard`'s `keyChangedHandler` reports every key's press AND release, wherever focus is
/// and whoever is first responder, and consumes nothing (UIKit still routes the same press). The
/// gate on what a press may do is `GridStore.holdOriginal`'s (only while the strip owns the
/// keys, so never into a text field's sheet), and a release is always passed on. A keyboard that
/// disconnects mid-hold sends its release from here, so the original cannot stick.
///
/// One monitor for the app, and every mounted loupe an OWNER of it: `attach` hands back a token,
/// a press goes to the most recent owner still attached, and its release goes to the owner that
/// got the press — even when another has attached since. `detach` releases the departing owner's
/// hold, if it has one, and the remaining most recent owner receives from then on. The last
/// `detach` stops listening altogether: no observers, no key handler.
@MainActor
final class OriginalKeyMonitor {
  static let shared = OriginalKeyMonitor(listensToKeyboard: true)

  private struct Owner {
    let token: Int
    let handler: (Bool) -> Void
  }

  /// False in unit tests: the owners and `deliver` without GameController.
  private let listensToKeyboard: Bool
  private var owners: [Owner] = []
  private var nextToken = 0
  /// The owner holding `\` now: the one its release goes to.
  private var pressedOwner: Int?
  private var observers: [NSObjectProtocol] = []

  init(listensToKeyboard: Bool) {
    self.listensToKeyboard = listensToKeyboard
  }

  /// The owners attached now.
  var ownerCount: Int { owners.count }

  /// Adds an owner; the key goes to it from now on. Keep the token for `detach`.
  func attach(_ handler: @escaping (Bool) -> Void) -> Int {
    let token = nextToken
    nextToken += 1
    owners.append(Owner(token: token, handler: handler))
    if owners.count == 1 { startListening() }
    return token
  }

  /// Removes the owner `token`, releasing its hold first when it holds the key.
  func detach(_ token: Int) {
    guard let index = owners.firstIndex(where: { $0.token == token }) else { return }
    let departing = owners.remove(at: index)
    if pressedOwner == token {
      pressedOwner = nil
      departing.handler(false)
    }
    if owners.isEmpty { stopListening() }
  }

  /// The delivery boundary: `\` pressed or released. A press goes to the most recent owner; a
  /// release to the owner that got the press, when it is still attached.
  func deliver(isPressed: Bool) {
    if isPressed {
      guard let owner = owners.last else { return }
      pressedOwner = owner.token
      owner.handler(true)
    } else {
      guard let token = pressedOwner else { return }
      pressedOwner = nil
      owners.first { $0.token == token }?.handler(false)
    }
  }

  /// Only the shared monitor listens (`listensToKeyboard`), so the GameController callbacks
  /// below name it rather than capturing `self`.
  private func startListening() {
    guard listensToKeyboard, observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: .GCKeyboardDidConnect, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { OriginalKeyMonitor.shared.listen() }
      })
    observers.append(
      center.addObserver(forName: .GCKeyboardDidDisconnect, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { OriginalKeyMonitor.shared.deliver(isPressed: false) }
      })
    listen()
  }

  private func stopListening() {
    guard listensToKeyboard else { return }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
  }

  /// Installs the key handler on the coalesced keyboard, when one is connected. The handler is
  /// called on the keyboard's handler queue; the hop to the main queue keeps press and release
  /// in their order (one serial queue), which a `Task` per event would not promise.
  private func listen() {
    let onKey: GCKeyboardValueChangedHandler = { @Sendable (_, _, keyCode, pressed) in
      guard keyCode == .backslash else { return }
      DispatchQueue.main.async {
        MainActor.assumeIsolated { OriginalKeyMonitor.shared.deliver(isPressed: pressed) }
      }
    }
    GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = onKey
  }
}
