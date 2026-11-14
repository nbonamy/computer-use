import AppKit
import CoreGraphics
import XCTest
@testable import ComputerUsePilotCore

final class KeyboardChordTests: XCTestCase {
  /// A background Open/Save panel drops modified shortcuts; Go To opens from
  /// a typed "/", cleared so the caller types the full path as usual.
  func testGoToFolderBecomesSlashThenBackspaceForRemotePanels() throws {
    for spelling in ["Super+Shift+g", "cmd+shift+G", "Shift+Super_L+g"] {
      XCTAssertEqual(try KeyboardChord.parse(spelling).remotePanelEquivalent(),
        [try KeyboardChord.parse("/"), try KeyboardChord.parse("BackSpace")])
    }
    XCTAssertNil(try KeyboardChord.parse("Return").remotePanelEquivalent())
    XCTAssertNil(try KeyboardChord.parse("Super+g").remotePanelEquivalent())
  }

  func testShortcutEventsCarryKeyCodeAndModifiers() throws {
    let events = try KeyboardChord.parse("Super+Shift+g").events()
    XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
    for event in events {
      XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 5)
      XCTAssertTrue(event.flags.contains(.maskCommand))
      XCTAssertTrue(event.flags.contains(.maskShift))
    }
    XCTAssertEqual(try KeyboardChord.parse("Shift+Super+g").events().map(\.flags), events.map(\.flags))
  }

  func testReturnAndLiteralTextRetainTheirCharacters() throws {
    for (key, text) in [("Return", "\r"), ("/", "/"), ("é", "é")] {
      let events = try KeyboardChord.parse(key).events()
      XCTAssertEqual(events.count, 2)
      XCTAssertEqual(NSEvent(cgEvent: events[0])?.characters, text)
    }
  }

  func testParsesAliasesAndWhitespace() throws {
    let chord = try KeyboardChord.parse(" Ctrl + Shift + a ")
    XCTAssertEqual(chord.keyCode, 0)
    XCTAssertTrue(chord.flags.contains(.maskControl))
    XCTAssertTrue(chord.flags.contains(.maskShift))
  }

  func testParsesNamedKeyAndLiteralUnicode() throws {
    XCTAssertEqual(try KeyboardChord.parse("Return").keyCode, 36)
    XCTAssertEqual(try KeyboardChord.parse("é").text, "é")
    XCTAssertEqual(try KeyboardChord.parse("A").text, "A")
  }

  func testRejectsUnknownModifier() {
    XCTAssertThrowsError(try KeyboardChord.parse("Hyper+a"))
  }
}
