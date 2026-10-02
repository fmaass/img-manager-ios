import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP30 P1 (IMGMGR-456): the loupe's toolbar is rendered FROM `LoupeChromeLayout`
/// (`LoupeToolbar` builds one `ToolbarItemGroup` per group), so these pin what the bar carries.
@Suite("Loupe chrome layout (WP30 P1)")
struct LoupeChromeLayoutTests {

  @Test("Regular with Info: exactly three groups — Back · title · Looks, Compare, Info, More")
  func regularWithInfo() {
    for mode in [LayoutMode.regular2, .regular3] {
      let layout = LoupeChromeLayout.make(layoutMode: mode, hasInfo: true)
      #expect(layout.groups.count == 3)
      #expect(layout.groups == [[.back], [.title], [.looks, .compare, .info, .more]])
    }
  }

  @Test("Compact without Info: Back · title · Looks, More — no Compare on the phone")
  func compactWithoutInfo() {
    let layout = LoupeChromeLayout.make(layoutMode: .compact, hasInfo: false)
    #expect(layout.groups == [[.back], [.title], [.looks, .more]])
  }

  @Test("Info appears only when the host has an inspector path")
  func infoFollowsTheHost() {
    #expect(
      LoupeChromeLayout.make(layoutMode: .regular2, hasInfo: false).groups
        == [[.back], [.title], [.looks, .compare, .more]])
    #expect(
      LoupeChromeLayout.make(layoutMode: .compact, hasInfo: true).groups
        == [[.back], [.title], [.looks, .info, .more]])
  }

  @Test(
    "IMGMGR-382: Looks leads the trailing group in every layout mode",
    arguments: [
      (LayoutMode.compact, false), (.compact, true), (.regular2, false), (.regular2, true),
      (.regular3, false), (.regular3, true),
    ])
  func looksLeadsTheTrailingGroup(mode: LayoutMode, hasInfo: Bool) {
    let trailing = LoupeChromeLayout.make(layoutMode: mode, hasInfo: hasInfo).trailing
    #expect(trailing.first == .looks)
    #expect(trailing.filter { $0 == .looks }.count == 1)
    #expect(trailing.last == .more)
  }

  @Test(
    "No item of any group is a zoom item (IMGMGR-348: no zoom pill returns)",
    arguments: [
      (LayoutMode.compact, false), (.compact, true), (.regular2, false), (.regular2, true),
      (.regular3, true),
    ])
  func noZoomItem(mode: LayoutMode, hasInfo: Bool) {
    let layout = LoupeChromeLayout.make(layoutMode: mode, hasInfo: hasInfo)
    #expect(layout.groups.count == 3)
    for item in layout.groups.flatMap({ $0 }) {
      #expect(!item.accessibilityIdentifier.lowercased().contains("zoom"))
      #expect(item.title.range(of: "%|Fit|100", options: .regularExpression) == nil)
    }
  }

  @Test("The shipped identifiers: Back replaces Close, More is a menu of its own")
  func identifiers() {
    #expect(LoupeChromeItem.back.accessibilityIdentifier == "loupeBack")
    #expect(LoupeChromeItem.title.accessibilityIdentifier == "loupeTitle")
    #expect(LoupeChromeItem.looks.accessibilityIdentifier == "loupeLooksButton")
    #expect(LoupeChromeItem.compare.accessibilityIdentifier == "loupeCompareButton")
    #expect(LoupeChromeItem.more.accessibilityIdentifier == "loupeMoreMenu")
    #expect(!LoupeChromeItem.allCases.contains { $0.accessibilityIdentifier == "loupeClose" })
  }
}

@Suite("Loupe title (WP30 P1)")
struct LoupeTitleTests {

  private func image(_ id: Int) -> Components.Schemas.ImageSummary {
    Components.Schemas.ImageSummary(
      aspectRatio: 1.5, capturedAt: nil, ext: "raf", filename: "DSCF\(id).raf", folderId: 1,
      hasEdit: false, id: id, lightroom: .init(sidecarPresent: false),
      mark: .init(revision: "r0", state: .none, tags: []), missing: false,
      proxies: .init(additionalProperties: [:]), sourceTier: "local")
  }

  @Test("n of N over the flat sequence: the focused photograph's 1-based position")
  func positionInSequence() {
    let scope = FilmstripScope.sequence([image(1), image(2), image(3), image(4)])
    #expect(
      LoupeTitle.text(shootTitle: "Stub Shoot", scope: scope, focusedImageID: 1)
        == "Stub Shoot · 1 of 4")
    #expect(
      LoupeTitle.text(shootTitle: "Stub Shoot", scope: scope, focusedImageID: 4)
        == "Stub Shoot · 4 of 4")
  }

  @Test("n of N over a scene band counts the band, not the stream")
  func positionInBand() {
    let scope = FilmstripScope.members([image(10), image(11), image(12)])
    #expect(
      LoupeTitle.text(shootTitle: "Stub Shoot", scope: scope, focusedImageID: 11)
        == "Stub Shoot · 2 of 3")
  }

  @Test("A single-frame scope reads 1 of 1")
  func singleFrame() {
    #expect(
      LoupeTitle.text(shootTitle: "S", scope: .sequence([image(7)]), focusedImageID: 7)
        == "S · 1 of 1")
  }

  @Test("Hidden scope (a loose photograph in Scene mode): the shoot name alone")
  func hiddenScopeFallsBack() {
    #expect(
      LoupeTitle.text(shootTitle: "Stub Shoot", scope: .hidden, focusedImageID: 5) == "Stub Shoot")
  }

  @Test("A scope that does not hold the focused photograph, or no focus: the shoot name alone")
  func focusOutsideTheScope() {
    let scope = FilmstripScope.sequence([image(1), image(2)])
    #expect(
      LoupeTitle.text(shootTitle: "Stub Shoot", scope: scope, focusedImageID: 99) == "Stub Shoot")
    #expect(
      LoupeTitle.text(shootTitle: "Stub Shoot", scope: scope, focusedImageID: nil) == "Stub Shoot")
    #expect(
      LoupeTitle.text(shootTitle: "Stub Shoot", scope: .sequence([]), focusedImageID: 1)
        == "Stub Shoot")
  }

  @Test("No shoot name: the position alone, never a leading separator")
  func noShootName() {
    let scope = FilmstripScope.sequence([image(1), image(2)])
    #expect(LoupeTitle.text(shootTitle: "", scope: scope, focusedImageID: 2) == "2 of 2")
    #expect(LoupeTitle.text(shootTitle: "", scope: .hidden, focusedImageID: 2) == "")
  }
}
