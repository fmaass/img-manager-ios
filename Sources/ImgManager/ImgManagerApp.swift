import SwiftUI

@main
struct ImgManagerApp: App {
  var body: some Scene {
    WindowGroup {
      #if DEBUG
        if DebugStubLaunch.isActive {
          // Diff-gate round 2, item 9(a): a DEBUG-only, launch-argument-gated fixture
          // composition for retained screenshot evidence — never reachable without BOTH the
          // Debug build configuration AND this explicit launch argument, and stripped entirely
          // from a Release/TestFlight archive.
          RootView(transport: DebugStubTransport())
        } else {
          RootView()
        }
      #else
        RootView()
      #endif
    }
    .commands {
      AppCommands()
    }
  }
}
