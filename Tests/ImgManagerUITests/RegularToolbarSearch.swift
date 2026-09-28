import XCTest

/// WP28 P2 (IMGMGR-449): reaching the Regular shell's toolbar search. The grid carries
/// `.searchable(placement: .toolbar)` with `.searchToolbarBehavior(.minimize)`, so at rest the
/// search is a toolbar BUTTON and a tap expands it into the field. The system button carries no
/// app identifier, so it is addressed by its label, and the field by its element type.
extension XCTestCase {

  /// The minimised search control, if the system exposes one as a button.
  func regularToolbarSearchButton(_ app: XCUIApplication) -> XCUIElement {
    app.buttons
      .matching(NSPredicate(format: "label ==[c] 'Search' OR identifier ==[c] 'Search'"))
      .firstMatch
  }

  /// Taps the minimised search open and returns the field once it is ACTIVE, or nil otherwise.
  ///
  /// Gate run on 20d9c58 (iPad, iOS 26.5): at rest the search is a 36×36 pt toolbar BUTTON
  /// labelled "Search" on the grid's bar and no search field exists; a tap on it puts a
  /// `SearchField` ("Search folders") on the bar. Active means more than "a field exists": the
  /// field is hittable and has keyboard focus, proven by typing a probe character that changes
  /// its value (then deleting it again). What was found is printed; the gate copies the log back.
  func expandRegularToolbarSearch(_ app: XCUIApplication, context: String) -> XCUIElement? {
    let button = regularToolbarSearchButton(app)
    let field = app.searchFields.firstMatch
    _ = button.waitForExistence(timeout: 10)
    let buttonHittable = button.exists && button.isHittable
    let reading = [
      "buttonExists=\(button.exists)",
      "buttonHittable=\(buttonHittable)",
      "fieldBefore=\(field.exists)",
      "buttonFrame=\(button.exists ? String(describing: button.frame) : "-")",
    ]
    print("IMGMGR-449-SEARCH \(context): " + reading.joined(separator: " "))
    guard buttonHittable else { return nil }
    button.tap()
    guard field.waitForExistence(timeout: 10), field.isHittable else {
      print("IMGMGR-449-SEARCH \(context): no hittable search field after the tap")
      return nil
    }
    let before = searchFieldText(field)
    field.typeText("q")
    let after = searchFieldText(field)
    field.typeText(XCUIKeyboardKey.delete.rawValue)
    print(
      "IMGMGR-449-SEARCH \(context): probe before=\"\(before)\" after=\"\(after)\" "
        + "buttonAfter=\(button.exists && button.isHittable)")
    guard after != before, after.hasSuffix("q") else { return nil }
    return field
  }

  /// The field's typed text: "" while it shows its placeholder (an empty search field reports
  /// the placeholder as its value — gate run 3 on 81c0ee8 read "Search folders").
  func searchFieldText(_ field: XCUIElement) -> String {
    let value = (field.value as? String) ?? ""
    return value == field.placeholderValue ? "" : value
  }

  /// Empties a search field that still has keyboard focus. At Regular the term is typed without a
  /// return: submitting leaves the minimised field unfocused, and the next tap on it collapsed it
  /// back into the button (gate run on 20d9c58). With focus kept, deleting is all it takes.
  func clearFocusedSearchField(_ field: XCUIElement) {
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 24))
  }

  /// Empties the Compact Search tab's field. Its clear control is not a stable handle; deleting
  /// the term is. The caret goes to the END first — a tap on the field's middle leaves it
  /// mid-term (gate run on 08367cc read "such-wandern"); should that tap land on the clear
  /// control instead, the term is cleared all the same.
  func clearSearchField(_ field: XCUIElement) {
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 24))
  }

  /// Whether a search field reads as empty (its value, or its placeholder).
  func searchFieldIsCleared(_ field: XCUIElement) -> Bool {
    searchFieldText(field).isEmpty
  }
}
