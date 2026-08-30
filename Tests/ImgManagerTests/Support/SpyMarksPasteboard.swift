import Foundation

@testable import ImgManager

/// WP13 P5a (IMGMGR-221): reads back exactly what "Copy for Lightroom" wrote, without touching
/// the system pasteboard — which is shared simulator state and would make the suite
/// order-dependent (and would say nothing about the local-only option the real one writes with;
/// `MarksExportCopyTests.pasteboardIsLocalOnlyNeverUniversalClipboard` asserts that separately,
/// on `SystemMarksPasteboard` itself).
@MainActor
final class SpyMarksPasteboard: MarksPasteboard {
  private(set) var writes: [String] = []

  func write(_ string: String) {
    writes.append(string)
  }
}

/// A `UserDefaults` suite nobody else shares, so a preference test can neither read nor leave
/// state in the simulator's standard domain.
@MainActor
func makeEphemeralDefaults() -> UserDefaults {
  let name = "img-manager.tests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: name)!
  defaults.removePersistentDomain(forName: name)
  return defaults
}
