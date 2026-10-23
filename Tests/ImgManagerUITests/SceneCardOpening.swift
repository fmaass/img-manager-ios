import Foundation
import XCTest

extension XCTestCase {

  /// Pushes scene `stackID` by tapping its CARD (IMGMGR-542: the chevron on the card,
  /// `sceneHandle-<id>`, opens the scene's peek band in place instead).
  ///
  /// Every card answers to `sceneCard`, so the card meant is the one whose frame holds this
  /// scene's chevron; the tap lands on the card's centre, away from the chevron in its corner.
  func pushScene(
    _ app: XCUIApplication, _ stackID: Int, timeout: TimeInterval = 15,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let handle = app.descendants(matching: .any)["sceneHandle-\(stackID)"].firstMatch
    XCTAssertTrue(
      handle.waitForExistence(timeout: timeout), "Scene \(stackID) has no card on screen.",
      file: file, line: line)
    let centre = CGPoint(x: handle.frame.midX, y: handle.frame.midY)
    let cards = app.descendants(matching: .any).matching(identifier: "sceneCard")
    var card = cards.firstMatch
    for index in 0..<cards.count {
      let candidate = cards.element(boundBy: index)
      if candidate.frame.contains(centre) {
        card = candidate
        break
      }
    }
    card.tap()
  }
}
