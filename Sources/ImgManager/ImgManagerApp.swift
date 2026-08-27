import SwiftUI

@main
struct ImgManagerApp: App {
  var body: some Scene {
    WindowGroup {
      RootView()
    }
    .commands {
      AppCommands()
    }
  }
}
