import XCTest

/// IMGMGR-539 (R3-11): the title-menu label pattern accepts exactly the breadcrumb subtitle's
/// closed vocabulary, in order, with grouped digits — and nothing that merely contains "photos".
/// Pure: no app launch (the pattern lives in this bundle, `MaterialsChrome.swift`, beside the
/// census that uses it). It still derives from the orientation-pinned base like every class in
/// this target (`ui-orientation-base-grep`): the pin costs nothing here and the rule has no
/// exemptions.
final class TitleMenuLabelPatternTests: OrientationPinnedUITestCase {

  private let names = ["Stub"]

  func testAcceptsTheClosedVocabulary() {
    let accepted = [
      "Stub",
      "Stub, 12 photos",
      "Stub, 1,200 photos · 1,200 picks · 5 edited",
      "Stub, 1,726 photos · untouched",
      "Stub, 12 photos · 10 picks · 5 edited · 5 marks not in Lightroom",
      "Stub, 1 photo · 1 pick, Actions Menu",
      "Stub, 1 photo · 1 mark not in Lightroom",
    ]
    for label in accepted {
      XCTAssertTrue(Self.isTitleMenuLabel(label, names: names), "should accept \"\(label)\"")
    }
  }

  func testRejectsUnknownReorderedAndMalformedSegments() {
    let rejected = [
      "Stub, 12 photos · 3 unmarked",
      "Stub, 12 photos · 2 dislikes",
      "Stub, 12 photos, Foo",
      "Stub, 1,20 photos",
      "Stub, 12 photos · edited 5",
      "Stub, 12 photos · 5 edited · 10 picks",
      "Stubby, 12 photos",
      "Stub, 12 photos · 5 marks not in Lightroom · 5 edited",
    ]
    for label in rejected {
      XCTAssertFalse(Self.isTitleMenuLabel(label, names: names), "should reject \"\(label)\"")
    }
  }
}
