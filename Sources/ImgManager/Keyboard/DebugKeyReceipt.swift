#if DEBUG
  import ObjectiveC
  import UIKit

  /// DEBUG-ONLY, fixture-only key-RECEIPT evidence (IMGMGR-483, review round 2). Compare handles
  /// no bare key of its own and the gate's simulators deliver no ⌘ key equivalents
  /// (IMGMGR-508), so "the keys went to Compare and did nothing" needs a record that the keys
  /// ARRIVED. The observation point is `UIApplication.sendEvent(_:)`, the boundary every
  /// hardware key press crosses before UIKit routes it to a key command or a responder — a
  /// window's `pressesBegan` would only see presses no earlier responder consumed, which would
  /// miss exactly the grid-handled `P`.
  ///
  /// It OBSERVES and never routes: the exchanged method records the press and then calls UIKit's
  /// own implementation with the same event; nothing is consumed. Each began press appends
  /// `<seq>:<key>:<disposition>` to `DebugProbe.keyReceipts`, where the disposition is whether
  /// the scene published the grid's key actions at that moment (`grid`) or Compare withheld them
  /// (`withheld`, `DebugProbe.gridKeysWithheld`, written by `RootView` from the published value).
  @MainActor
  enum DebugKeyReceipt {
    private static var isInstalled = false

    static func installIfNeeded() {
      guard DebugStubLaunch.isActive, !isInstalled else { return }
      isInstalled = true
      let original = #selector(UIApplication.sendEvent(_:))
      let observing = #selector(UIApplication.debugKeyReceiptSendEvent(_:))
      guard
        let originalMethod = class_getInstanceMethod(UIApplication.self, original),
        let observingMethod = class_getInstanceMethod(UIApplication.self, observing)
      else { return }
      method_exchangeImplementations(originalMethod, observingMethod)
    }

    static func record(_ event: UIEvent) {
      guard event.type == .presses, let presses = (event as? UIPressesEvent)?.allPresses else {
        return
      }
      let probe = DebugProbe.shared
      for press in presses where press.phase == .began {
        guard let key = press.key else { continue }
        let name =
          key.keyCode == .keyboardRightArrow
          ? "rightArrow" : key.charactersIgnoringModifiers.lowercased()
        let disposition = probe.gridKeysWithheld ? "withheld" : "grid"
        probe.keyReceipts.append("\(probe.keyReceipts.count + 1):\(name):\(disposition)")
      }
    }
  }

  extension UIApplication {
    /// After the exchange this selector names UIKit's original `sendEvent(_:)`, so the call
    /// below delivers the event exactly as UIKit would have.
    @objc dynamic func debugKeyReceiptSendEvent(_ event: UIEvent) {
      DebugKeyReceipt.record(event)
      debugKeyReceiptSendEvent(event)
    }
  }
#endif
