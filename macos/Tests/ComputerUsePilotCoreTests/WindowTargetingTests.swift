import CoreGraphics
import ApplicationServices
import XCTest
@testable import ComputerUsePilotCore

final class WindowTargetingTests: XCTestCase {
  @MainActor
  func testBackgroundKeyboardSelectionDoesNotRaiseWindow() throws {
    let app = AXUIElementCreateApplication(101)
    let window = AXUIElementCreateApplication(102)
    var focused = app
    var raises = 0
    let targeting = WindowTargeting(attributeReader: { _, name in
      name == kAXFocusedWindowAttribute ? focused : nil
    }, focusRequester: { focused = $0 }, raiseRequester: { _ in raises += 1 })
    try targeting.focus(window, app: app)
    XCTAssertEqual(raises, 0)
    focused = app
    try targeting.focus(window, app: app, allowRaise: true)
    XCTAssertEqual(raises, 1)
  }

  @MainActor
  func testKeyboardFocusSelectsExactWindowAndVerifiesIt() throws {
    let first = AXUIElementCreateApplication(101)
    let second = AXUIElementCreateApplication(102)
    var focused = first
    var requests = 0
    let targeting = WindowTargeting(attributeReader: { _, name in
      name == kAXFocusedWindowAttribute ? focused : nil
    }, focusRequester: { window in
      requests += 1
      focused = window
    })
    try targeting.focus(first, app: first)
    XCTAssertEqual(requests, 0)
    try targeting.focus(second, app: first)
    XCTAssertEqual(requests, 1)
    XCTAssertTrue(targeting.isKeyboardTarget(second, app: first))
  }

  @MainActor
  func testKeyboardFocusFailsWhenAppKeepsAnotherWindowSelected() {
    let first = AXUIElementCreateApplication(101)
    let second = AXUIElementCreateApplication(102)
    let targeting = WindowTargeting(attributeReader: { _, name in
      name == kAXFocusedWindowAttribute ? first : nil
    }, focusRequester: { _ in })
    XCTAssertThrowsError(try targeting.focus(second, app: first)) { error in
      XCTAssertEqual((error as? PilotRuntimeError)?.code, "window_focus_failed")
    }
  }

  @MainActor
  func testElementOwnershipRejectsAnotherWindow() {
    let first = AXUIElementCreateApplication(101)
    let second = AXUIElementCreateApplication(102)
    let child = AXUIElementCreateApplication(103)
    let targeting = WindowTargeting(attributeReader: { element, name in
      if CFEqual(element, child) && name == kAXWindowAttribute { return second }
      return nil
    })
    XCTAssertTrue(targeting.contains(child, window: second))
    XCTAssertFalse(targeting.contains(child, window: first))
  }

  func testWindowIDSurvivesReordering() throws {
    let selection = WindowSelection<String>(equal: ==)
    let id = selection.id(for: "b", pid: 1)
    let first = try selection.resolve(pid: 1, requested: id, windows: ["a", "b"])
    let next = try selection.resolve(pid: 1, requested: id, windows: ["b", "a"])
    XCTAssertEqual(first.id, next.id)
    XCTAssertEqual(next.element, "b")
  }

  func testListingPreservesIDsAndEveryResolutionUsesItsExplicitID() throws {
    let selection = WindowSelection<String>(equal: ==)
    let firstID = selection.id(for: "a", pid: 1)
    let otherID = selection.id(for: "b", pid: 1)
    XCTAssertEqual(selection.id(for: "a", pid: 1), firstID)
    XCTAssertEqual(try selection.resolve(pid: 1, requested: firstID, windows: ["a", "b"]).element, "a")
    XCTAssertEqual(try selection.resolve(pid: 1, requested: otherID, windows: ["a", "b"]).element, "b")
  }

  func testClosedSelectionNeverFallsBackAndCanBeReplacedExplicitly() throws {
    let selection = WindowSelection<String>(equal: ==)
    let oldID = selection.id(for: "a", pid: 1)
    XCTAssertThrowsError(try selection.resolve(pid: 1, requested: oldID, windows: ["b"]))
    let newID = selection.id(for: "b", pid: 1)
    XCTAssertEqual(try selection.resolve(pid: 1, requested: newID, windows: ["b"]).element, "b")
  }

  func testIDsAreAppBoundAndUnknownIDsDoNotFallback() throws {
    let selection = WindowSelection<String>(equal: ==)
    let id = selection.id(for: "a", pid: 1)
    XCTAssertThrowsError(try selection.resolve(pid: 2, requested: id, windows: ["a"]))
    XCTAssertThrowsError(try selection.resolve(pid: 1, requested: 999, windows: ["a"]))
    XCTAssertThrowsError(try selection.resolve(pid: 1, requested: id, windows: []))
  }

  func testWindowCaptureRequiresBothTitleAndGeometry() {
    let bounds = CGRect(x: -1700, y: 40, width: 1600, height: 900)
    let target = WindowCaptureTarget(windowID: 1, title: "Example", bounds: bounds)
    XCTAssertTrue(target.matches(title: "Example", bounds: bounds))
    XCTAssertFalse(target.matches(title: "GitHub", bounds: bounds))
    XCTAssertFalse(target.matches(title: "Example", bounds: bounds.offsetBy(dx: 1700, dy: 0)))
    XCTAssertTrue(target.matches(title: "Example", bounds: bounds.offsetBy(dx: 0.5, dy: 0)))
  }
}
