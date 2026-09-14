import CoreGraphics
import XCTest
@testable import ComputerUsePilotCore

final class KeyboardChordTests: XCTestCase {
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
