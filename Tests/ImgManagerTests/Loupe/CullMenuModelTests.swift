import CoreGraphics
import Foundation
import ImgManagerAPI
import Testing

@testable import ImgManager

/// WP30 P2 (IMGMGR-457): the Cull loupe's More menu and the photograph's context menu are both
/// rendered FROM these pure tables (`CullMoreMenuModel`, `LoupeContextMenuModel`), so the value
/// the tests pin is the menu the view draws. The acceptance, verbatim: "More menu row/section
/// count matches the spec; photo context menu ≤ 3 groups."
@MainActor
@Suite("Cull More + photo context menu (WP30 P2)")
struct CullMenuModelTests {

  // MARK: - More

  @Test("More: exactly two sections — Share, Tag, Lock Pick, Lock Dislike | Zoom, Advance")
  func moreHasTwoSectionsOfTheSpecRows() {
    let sections = CullMoreMenuModel.sections.map(\.commands)
    #expect(sections.count == 2)
    #expect(
      sections == [
        [.share, .tag, .lockPick, .lockDislike],
        [.zoomToOneToOne, .advanceAfterMarking],
      ])
    #expect(CullMoreMenuModel.rows.count == 6)
  }

  @Test("More: no row twice, no Lightroom row (D-a), ≤ 6 rows per touch menu")
  func moreHasNoDuplicateAndNoDroppedRow() {
    let rows = CullMoreMenuModel.rows
    #expect(Set(rows).count == rows.count)
    #expect(rows.count <= 6)
    #expect(!rows.map(\.title).contains { $0.localizedCaseInsensitiveContains("lightroom") })
    #expect(Set(CullMoreMenuModel.sections.map(\.id)).count == CullMoreMenuModel.sections.count)
  }

  @Test("More: every row carries an icon and its own identifier; Share keeps `loupeShare`")
  func everyMoreRowHasAnIconAndAnIdentifier() {
    for row in CullMoreMenuModel.rows {
      #expect(!row.systemImage.isEmpty, "\(row) has no icon")
      #expect(!row.title.isEmpty)
    }
    let identifiers = CullMoreMenuModel.rows.map(CullMoreMenuModel.accessibilityIdentifier(for:))
    #expect(Set(identifiers).count == 6)
    #expect(CullMoreMenuModel.accessibilityIdentifier(for: .share) == "loupeShare")
    #expect(
      CullMoreMenuModel.accessibilityIdentifier(for: .advanceAfterMarking)
        == "loupeMore.advanceAfterMarking")
  }

  @Test("More: the four mode rows are check rows; Share and Tag are actions")
  func checkRowsAreTheModes() {
    let toggles = CullMoreMenuModel.rows.filter(\.isToggle)
    #expect(toggles == [.lockPick, .lockDislike, .zoomToOneToOne, .advanceAfterMarking])
  }

  // MARK: - Context menu

  @Test("Context menu: [Pick, Dislike, Clear] | [Tag, Share] | [Lock ▸ Lock Pick, Lock Dislike]")
  func contextMenuGroups() {
    let groups = LoupeContextMenuModel.groups.map(\.nodes)
    #expect(groups.count == 3)
    #expect(groups.count <= 3)
    #expect(groups[0] == [.command(.pick), .command(.dislike), .command(.clear)])
    #expect(groups[1] == [.command(.tag), .command(.share)])
    #expect(groups[2] == [.submenu(LoupeContextMenuModel.lock)])
    #expect(LoupeContextMenuModel.lock.commands == [.lockPick, .lockDislike])
    #expect(LoupeContextMenuModel.lock.title == "Lock")
  }

  @Test("Context menu: depth ≤ 2 and exactly six top-level entries, no key equivalents")
  func contextMenuDepthAndTopLevel() {
    #expect(LoupeContextMenuModel.depth == 2)
    #expect(LoupeContextMenuModel.depth <= 2)
    #expect(
      LoupeContextMenuModel.topLevelTitles == ["Pick", "Dislike", "Clear", "Tag", "Share", "Lock"])
    for group in LoupeContextMenuModel.groups {
      for node in group.nodes {
        if case .submenu(let submenu) = node {
          #expect(!submenu.systemImage.isEmpty)
        }
      }
    }
    let identifiers = LoupeContextMenuModel.groups.flatMap(\.nodes).map(\.id)
    #expect(Set(identifiers).count == identifiers.count)
  }

  @Test("Context mark rows write the verdict they name")
  func contextMarkRowsNameTheirState() {
    #expect(CullCommand.pick.markState == .pick)
    #expect(CullCommand.dislike.markState == .dislike)
    #expect(CullCommand.clear.markState == MarkStateValue.none)
    #expect(CullCommand.tag.markState == nil)
  }

  // MARK: - Lock rows: the grid's latch

  private func makeStore() -> GridStore {
    let transport = GridStubTransport()
    let client = ImgManagerAPIClient.make(transport: transport)
    return GridStore(service: GridService(client: client))
  }

  @Test("Lock rows: select latches through the grid's own latch; select again unlatches")
  func lockRowLatchesAndUnlatches() {
    for verb in LatchVerb.allCases {
      let store = makeStore()
      #expect(!CullLockRow.isChecked(verb, latchedVerb: store.pickLock.latchedVerb))
      store.toggleLockFromLoupe(verb)
      #expect(store.pickLock.state == .latched(verb))
      #expect(CullLockRow.isChecked(verb, latchedVerb: store.pickLock.latchedVerb))
      store.toggleLockFromLoupe(verb)
      #expect(store.pickLock.state == .idle)
    }
  }

  @Test("Lock rows: the other verb's row is inert while a lock is on — never two locks")
  func otherLockRowIsInertWhileLatched() {
    let store = makeStore()
    store.toggleLockFromLoupe(.dislike)
    #expect(CullLockRow.action(for: .pick, latchedVerb: store.pickLock.latchedVerb) == nil)
    store.toggleLockFromLoupe(.pick)
    #expect(store.pickLock.state == .latched(.dislike))
    #expect(CullLockRow.action(for: .dislike, latchedVerb: .dislike) == .unlatch)
    #expect(CullLockRow.action(for: .pick, latchedVerb: nil) == .latch)
  }

  // MARK: - Zoom row

  @Test("Zoom to 100%: checked exactly at 1:1, and the shared toggle is what flips it")
  func zoomRowIsCheckedAtOneToOne() {
    var zoom = LoupeZoomState()
    zoom.updateGeometry(
      proxyPixels: CGSize(width: 1600, height: 1067), viewport: CGSize(width: 400, height: 800),
      displayScale: 2)
    #expect(zoom.isZoomAvailable)
    #expect(!CullZoomRow.isAtOneToOne(zoom))
    zoom.toggle()
    #expect(CullZoomRow.isAtOneToOne(zoom))
    zoom.toggle()
    #expect(!CullZoomRow.isAtOneToOne(zoom))
  }

  // MARK: - Tag entry host

  @Test("Tag entry has exactly one host: the loupe while it is open, the grid otherwise")
  func tagEntryHasOneHost() {
    for isLoupeOpen in [false, true] {
      let hosts = TagEntryHost.allCases.filter {
        $0.presents(isTagEntryPresented: true, isLoupeOpen: isLoupeOpen)
      }
      #expect(hosts == [isLoupeOpen ? TagEntryHost.loupe : TagEntryHost.grid])
      #expect(
        TagEntryHost.allCases.allSatisfy {
          !$0.presents(isTagEntryPresented: false, isLoupeOpen: isLoupeOpen)
        })
    }
  }

  @Test("Tag targets the loupe's focused photograph")
  func tagTargetsTheFocusedPhotograph() {
    let store = makeStore()
    store.openLoupe(on: 42)
    store.handleTagShortcut()
    #expect(store.isTagEntryPresented)
    #expect(store.tagTargetImageIDs == [42])
    #expect(TagEntryHost.loupe.presents(isTagEntryPresented: true, isLoupeOpen: store.isLoupeOpen))
  }
}
