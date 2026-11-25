import XCTest

final class PinHeadlessUITests: XCTestCase {
 let app = XCUIApplication(bundleIdentifier: "org.pinmemory.Pin")

 override func setUp() {
  super.setUp()
  continueAfterFailure = false
 }

 func capture(_ name: String) {
  let attachment = XCTAttachment(screenshot: app.screenshot())
  attachment.name = name
  attachment.lifetime = .keepAlways
  add(attachment)
 }

 func submit(_ text: String) {
  let field = app.textFields["question"]
  XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
  field.tap()
  field.typeText(text)
  XCTAssertEqual(field.value as? String, text)
  field.typeText("\n")
 }
 func testItineraryOriginals() throws {
  app.launch()
  if app.buttons["allowPhotos"].waitForExistence(timeout: 3) {
   app.buttons["allowPhotos"].tap()
   let alert = XCUIApplication(bundleIdentifier:"com.apple.springboard").alerts.firstMatch
   if alert.waitForExistence(timeout:5) {
    let full = alert.buttons.matching(NSPredicate(format:"label CONTAINS[c] %@", "full")).firstMatch
    XCTAssertTrue(full.exists,alert.debugDescription)
    full.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
   }
  }
  let ready = NSPredicate { _,_ in
   self.app.staticTexts["14 photos read"].exists || self.app.staticTexts["8 photos read"].exists
  }
  XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:ready,object:nil)], timeout:60),.completed,app.debugDescription)
  submit("Compare the change notice and the departure board for train R581.")
  let heading = app.staticTexts["itineraryHeading"]
  XCTAssertTrue(heading.waitForExistence(timeout:60),app.debugDescription)
  let notice = app.buttons["itinerary-Service update"]
  let board = app.buttons["itinerary-Departure board snapshot"]
  let saved = try XCTUnwrap(app.staticTexts.allElementsBoundByIndex.first { $0.label.contains("Platform · 3") })
  let observed = try XCTUnwrap(app.staticTexts.allElementsBoundByIndex.first { $0.label.contains("Platform · 5") })
  let expected = [heading.label,saved.label,observed.label]
  capture("itinerary-answer")
  for (button,name) in [(notice,"notice"),(board,"board")] {
   XCTAssertTrue(button.isHittable,app.debugDescription)
   button.tap()
   XCTAssertTrue(app.navigationBars["Original photo"].waitForExistence(timeout:8),app.debugDescription)
   capture(name+"-original")
   app.buttons["Done"].tap()
   XCTAssertTrue(heading.waitForExistence(timeout:8),app.debugDescription)
   XCTAssertTrue(notice.isHittable && board.isHittable)
   XCTAssertEqual([heading.label,saved.label,observed.label],expected)
   capture(name+"-returned")
  }
  app.buttons["Pin home"].tap()
  submit("For BA629 to R581, reconstruct my itinerary with all saved changes. Give departure, gap after landing, destination hotel and platform.")
  XCTAssertTrue(app.staticTexts["84 minutes between the recorded arrival and departure."].waitForExistence(timeout:25),app.debugDescription)
  XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "Fern Court")).firstMatch.exists)
  XCTAssertTrue(notice.exists)
  capture("updated-itinerary")
  app.buttons["Pin home"].tap()
  submit("BA629 then R581 tonight. Put the onward time, minutes to change, bed for the night and platform together for me.")
  XCTAssertTrue(app.staticTexts["84 minutes between the recorded arrival and departure."].waitForExistence(timeout:25),app.debugDescription)
  XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@", "Fern Court")).firstMatch.exists)
  XCTAssertTrue(notice.exists)
  capture("nativ-itinerary")
 }
}
