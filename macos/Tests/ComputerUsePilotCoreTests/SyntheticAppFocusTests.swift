import AppKit
import CoreGraphics
import XCTest
@testable import ComputerUsePilotCore

final class SyntheticAppFocusTests: XCTestCase {
  func testActivationEventTellsTheAppItBecameActiveForTheWindow() throws {
    let event = try XCTUnwrap(SyntheticAppFocus.activationEvent(windowID: 4242))
    let decoded = try XCTUnwrap(NSEvent(cgEvent: event))
    XCTAssertEqual(decoded.type, .appKitDefined)
    XCTAssertEqual(decoded.subtype.rawValue, NSEvent.EventSubtype.applicationActivated.rawValue)
    XCTAssertEqual(decoded.windowNumber, 4242)
  }

  func testFocusClickIsRoutedToTheWindowWithoutUsingTheSharedPointer() throws {
    let point = CGPoint(x: -1200, y: 340)
    let events = SyntheticAppFocus.clickEvents(at: point, windowID: 4242)
    XCTAssertEqual(events.map(\.type), [.leftMouseDown, .leftMouseUp])
    for event in events {
      XCTAssertEqual(event.location, point)
      XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 1)
      XCTAssertEqual(event.getIntegerValueField(SyntheticAppFocus.windowUnderPointerField), 4242)
      XCTAssertEqual(event.getIntegerValueField(SyntheticAppFocus.windowThatCanHandleEventField), 4242)
      XCTAssertEqual(NSEvent(cgEvent: event)?.windowNumber, 4242)
    }
  }
}
