/// Which window the sign-in is put on — decided on a description of the app's scenes rather
/// than on the scenes themselves, so the decision can be tested.
///
/// Ported verbatim (logic unchanged) from memos-ng-ios's
/// `MemosFeatures/LoginAnchor.swift`. `UIApplication.connectedScenes` is a SET: it has no
/// order, so "the first one" is not the one in front. Getting this wrong is invisible on a
/// simulator with a single scene and a real bug on a device with more than one — the sign-in
/// view would be presented somewhere nobody is looking, indistinguishable from a button that
/// did nothing.
///
/// There is deliberately no last resort here: a window scene that is background or unattached
/// is not a place to present on, so "nowhere to present" is a value the caller has to handle
/// rather than a silent no-op.
enum LoginAnchor {
  /// A window scene as the decision sees it. Nothing about UIKit survives into the decision
  /// itself.
  struct SceneState: Equatable, Sendable {
    let activation: Activation
    /// One entry per window of the scene, in the scene's own order; `true` for the key window.
    let windowIsKey: [Bool]
  }

  enum Activation: Equatable, Sendable {
    case foregroundActive
    case foregroundInactive
    case background
    case unattached
  }

  /// Where the sign-in goes, as indices back into the list that was described.
  enum Choice: Equatable, Sendable {
    case window(scene: Int, window: Int)
    /// No connected scene is on screen with a window to present on.
    case nowhereToPresent
  }

  /// The scene the person is actually looking at, and the window on it that owns the screen.
  /// Foreground-active scenes are considered before foreground-inactive ones (an app returning
  /// from the app switcher is inactive, and its window is still the one on screen). Background
  /// and unattached scenes are never considered.
  static func choice(among scenes: [SceneState]) -> Choice {
    let order: [Activation] = [.foregroundActive, .foregroundInactive]
    for activation in order {
      for (index, scene) in scenes.enumerated() where scene.activation == activation {
        guard let window = scene.windowIsKey.firstIndex(of: true) ?? scene.firstWindow else {
          continue
        }
        return .window(scene: index, window: window)
      }
    }
    return .nowhereToPresent
  }
}

extension LoginAnchor.SceneState {
  /// `0` when the scene has any window at all; a scene with none is skipped.
  fileprivate var firstWindow: Int? { windowIsKey.isEmpty ? nil : 0 }
}
