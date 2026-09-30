import ImgManagerAPI
import SwiftUI

/// WP30 P1 (IMGMGR-456): what the loupe's system toolbar needs from the shell that hosts it —
/// the shoot's name for the title, and the one inspector's toggle. Injected by the two hosts:
/// `WorkspaceContent`'s loupe branch at Regular, `RootView`'s full-screen cover at Compact.
struct LoupeChrome {
  /// The inspector the grid bar's Info already toggles (`ShellToolbarControl.info`), as a
  /// snapshot of its state plus the one action that flips it.
  struct Info {
    let isPresented: Bool
    let toggle: @MainActor () -> Void
  }

  /// The shoot's name as the grid breadcrumb shows it; empty when no folder is known.
  let shootTitle: String
  /// Nil where the host has no inspector path (the Compact cover): Info is then not built.
  let info: Info?

  static var none: LoupeChrome { LoupeChrome(shootTitle: "", info: nil) }
}

/// One control of the loupe's navigation bar. There is deliberately no zoom item: IMGMGR-348
/// removed the zoom chrome and p4128 D4 puts Fit/100% inside More (P2), never on the bar.
enum LoupeChromeItem: CaseIterable, Hashable, Sendable {
  case back
  case title
  case compare
  case info
  case more

  var accessibilityIdentifier: String {
    switch self {
    case .back: "loupeBack"
    case .title: "loupeTitle"
    case .compare: "loupeCompareButton"
    case .info: "loupeInfoButton"
    case .more: "loupeMoreMenu"
    }
  }

  /// The spoken/visible name of the control (the title's own text is dynamic, see `LoupeTitle`).
  var title: String {
    switch self {
    case .back: "Back"
    case .title: "Title"
    case .compare: "Compare"
    case .info: "Info"
    case .more: "More"
    }
  }
}

/// The loupe toolbar as a VALUE: exactly three groups — leading Back, principal title, trailing
/// Compare · Info · More — in that order. `LoupeToolbar` renders one `ToolbarItemGroup` per
/// group from this, so a test on the value pins what the bar carries.
struct LoupeChromeLayout: Equatable, Sendable {
  let groups: [[LoupeChromeItem]]

  private init(groups: [[LoupeChromeItem]]) { self.groups = groups }

  static func make(layoutMode: LayoutMode, hasInfo: Bool) -> LoupeChromeLayout {
    var trailing: [LoupeChromeItem] = []
    // Compare is an iPad verb (p4128 "Open items" 2): never built at Compact.
    if layoutMode != .compact { trailing.append(.compare) }
    if hasInfo { trailing.append(.info) }
    trailing.append(.more)
    return LoupeChromeLayout(groups: [[.back], [.title], trailing])
  }

  var leading: [LoupeChromeItem] { groups[0] }
  var principal: [LoupeChromeItem] { groups[1] }
  var trailing: [LoupeChromeItem] { groups[2] }
}

/// The principal title, "<shoot name> · n of N": n is the focused photograph's 1-based position
/// in the filmstrip scope, N that scope's size. When the scope is `.hidden`, or does not hold the
/// focused photograph, there is no position to state and the title is the shoot name alone.
enum LoupeTitle {
  static func text(shootTitle: String, scope: FilmstripScope, focusedImageID: Int?) -> String {
    let frames = scope.frames
    guard let focusedImageID, let index = frames.firstIndex(where: { $0.id == focusedImageID })
    else {
      return shootTitle
    }
    let position = "\(index + 1) of \(frames.count)"
    return shootTitle.isEmpty ? position : "\(shootTitle) · \(position)"
  }
}

/// The three groups of `LoupeChromeLayout`, each one `ToolbarItemGroup`, in its placement.
struct LoupeToolbar<Item: View>: ToolbarContent {
  let layout: LoupeChromeLayout
  @ViewBuilder let item: @MainActor (LoupeChromeItem) -> Item

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarLeading) {
      ForEach(layout.leading, id: \.self) { item($0) }
    }
    ToolbarItemGroup(placement: .principal) {
      ForEach(layout.principal, id: \.self) { item($0) }
    }
    ToolbarItemGroup(placement: .primaryAction) {
      ForEach(layout.trailing, id: \.self) { item($0) }
    }
  }
}
