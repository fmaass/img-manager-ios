#if DEBUG
  import Foundation
  import QuartzCore
  import os

  /// IMGMGR-542 (R3-22): counts missed frames while the grid scrolls, under
  /// `-UITestFrameMonitor` only. A window opens when the grid's scroll phase leaves idle and
  /// closes when it returns there; each window is one "GridScrollWindow" signpost interval
  /// (subsystem `app.imgmanager`, category `GridScroll`), and each long frame inside it a nested
  /// "LongFrame" interval. Frames outside a window are never counted. The display link is pinned
  /// to 60 Hz, so a frame is long past 25 ms on every destination. The counts are published through
  /// `DebugProbe` for `PeekBandScrollMetricsUITests`.
  @MainActor
  final class GridFrameMonitor: NSObject {
    static let shared = GridFrameMonitor()
    static var isOn: Bool {
      ProcessInfo.processInfo.arguments.contains("-UITestFrameMonitor")
    }
    /// A frame is long when its gap exceeds this many frame durations, i.e. at least one frame
    /// was missed (25 ms at 60 Hz). The earlier fixed 0.0167 s budget sat just above the 16.667 ms
    /// frame period and so counted vsync jitter as long frames.
    static let missedFrameFactor: CFTimeInterval = 1.5

    private let signposter = OSSignposter(subsystem: "app.imgmanager", category: "GridScroll")
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var window: OSSignpostIntervalState?

    func scrollPhaseChanged(isScrolling: Bool) {
      guard Self.isOn else { return }
      if isScrolling { begin() } else { end() }
    }

    private func begin() {
      guard window == nil else { return }
      window = signposter.beginInterval("GridScrollWindow", id: signposter.makeSignpostID())
      DebugProbe.shared.debugScrollWindows += 1
      lastTimestamp = nil
      let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
      link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
      link.add(to: .main, forMode: .common)
      self.link = link
    }

    private func end() {
      link?.invalidate()
      link = nil
      if let window { signposter.endInterval("GridScrollWindow", window) }
      window = nil
      lastTimestamp = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
      defer { lastTimestamp = link.timestamp }
      guard window != nil, let last = lastTimestamp else { return }
      let delta = link.timestamp - last
      // The link's own frame duration at its pinned rate (1/60 s), not `duration`, which
      // reports the display's maximum refresh rate.
      let frameDuration = link.targetTimestamp - link.timestamp
      guard delta > Self.missedFrameFactor * frameDuration else { return }
      let state = signposter.beginInterval(
        "LongFrame", id: signposter.makeSignpostID(), "ms=\(Int(delta * 1000))")
      signposter.endInterval("LongFrame", state)
      DebugProbe.shared.debugLongFrames += 1
    }
  }
#endif
