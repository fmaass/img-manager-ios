import SwiftUI
import Testing

@testable import ImgManager

/// IMGMGR-478: the Regular sidebar's remembered visibility and the grid bar's way back to it, as
/// values. The rendered half — hide with the system toggle, restore from the grid's bar, the
/// relaunch — is `RegularSidebarShellUITests`.
@MainActor
@Suite("SidebarVisibilityMemory — a hidden Regular sidebar is remembered and has a way back")
struct SidebarVisibilityMemoryTests {

  private static let allModes: [LayoutMode] = [.compact, .regular2, .regular3]
  private static let shownValues: [NavigationSplitViewVisibility] = [
    .all, .doubleColumn, .automatic,
  ]

  @Test("A fresh install (the default flag) is the resolver's layout at every width")
  func freshInstallIsTheResolversLayout() {
    #expect(SidebarVisibilityMemory.hiddenDefault == false)
    let fresh = SidebarVisibilityMemory.hiddenDefault
    for mode in Self.allModes {
      let launch = SidebarVisibilityMemory.columnVisibility(for: mode, sidebarHidden: fresh)
      let resolver = LayoutResolver.columnVisibility(for: mode)
      #expect(launch == resolver, "A fresh install at \(mode) is not the resolver's layout")
    }
    // The resolver's own answers are untouched by this story.
    #expect(LayoutResolver.columnVisibility(for: .regular3) == .all)
    #expect(LayoutResolver.columnVisibility(for: .regular2) == .doubleColumn)
    #expect(LayoutResolver.columnVisibility(for: .compact) == .doubleColumn)
  }

  @Test("A remembered hidden sidebar comes back hidden at Regular, and never reaches Compact")
  func rememberedHiddenIsRegularOnly() {
    for mode in [LayoutMode.regular2, .regular3] {
      let restored = SidebarVisibilityMemory.columnVisibility(for: mode, sidebarHidden: true)
      #expect(restored == .detailOnly, "A remembered hidden sidebar is not hidden at \(mode)")
    }
    let compact = SidebarVisibilityMemory.columnVisibility(for: .compact, sidebarHidden: true)
    #expect(compact == LayoutResolver.columnVisibility(for: .compact))
  }

  @Test("Only a Regular split records; hidden is .detailOnly and every shown value records false")
  func recordingIsRegularOnly() {
    for mode in [LayoutMode.regular2, .regular3] {
      #expect(SidebarVisibilityMemory.recordedHidden(.detailOnly, in: mode) == true)
      for shown in Self.shownValues {
        #expect(SidebarVisibilityMemory.recordedHidden(shown, in: mode) == false)
      }
    }
    // Compact: the split is not on screen, so its `.doubleColumn` (or anything) never overwrites
    // what the reader chose at Regular.
    #expect(SidebarVisibilityMemory.recordedHidden(.detailOnly, in: .compact) == nil)
    #expect(SidebarVisibilityMemory.recordedHidden(.doubleColumn, in: .compact) == nil)
  }

  @Test("The grid bar carries the toggle exactly while the Regular sidebar is hidden")
  func toggleIsOnTheBarWhileHidden() {
    for mode in [LayoutMode.regular2, .regular3] {
      #expect(SidebarVisibilityMemory.showsGridBarToggle(in: mode, visibility: .detailOnly))
      for shown in Self.shownValues {
        #expect(!SidebarVisibilityMemory.showsGridBarToggle(in: mode, visibility: shown))
      }
    }
    for visibility in Self.shownValues + [.detailOnly] {
      #expect(!SidebarVisibilityMemory.showsGridBarToggle(in: .compact, visibility: visibility))
    }
  }

  @Test("The toggle shows the resolver's layout from hidden, hides from shown, and says which")
  func toggleActionAndLabel() {
    for mode in [LayoutMode.regular2, .regular3] {
      let restored = SidebarVisibilityMemory.toggled(.detailOnly, in: mode)
      #expect(restored == LayoutResolver.columnVisibility(for: mode))
      for shown in Self.shownValues {
        #expect(SidebarVisibilityMemory.toggled(shown, in: mode) == .detailOnly)
      }
    }
    #expect(SidebarVisibilityMemory.label(for: .detailOnly) == "Show Sidebar")
    for shown in Self.shownValues {
      #expect(SidebarVisibilityMemory.label(for: shown) == "Hide Sidebar")
    }
    // The UI test spells the identifier as a literal; this is the join.
    #expect(SidebarVisibilityMemory.toggleIdentifier == "regularSidebarToggle")
  }

  @Test("The flag is the shell's own key, not a grid preference")
  func theKeyIsTheShells() {
    #expect(SidebarVisibilityMemory.hiddenKey == "shell.regularSidebarHidden")
    #expect(!GridPreferences.persistedKeys.contains(SidebarVisibilityMemory.hiddenKey))
  }
}
