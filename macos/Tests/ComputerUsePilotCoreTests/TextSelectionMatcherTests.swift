import XCTest
@testable import ComputerUsePilotCore

final class TextSelectionMatcherTests: XCTestCase {
  func testFindsUTF16Range() throws {
    let range = try TextSelectionMatcher.uniqueRange(
      in: "A 👋 hello",
      text: "hello",
      prefix: nil,
      suffix: nil
    )
    XCTAssertEqual(range, NSRange(location: 5, length: 5))
  }

  func testContextDisambiguatesRepeatedText() throws {
    let range = try TextSelectionMatcher.uniqueRange(
      in: "first value, second value.",
      text: "value",
      prefix: "second ",
      suffix: "."
    )
    XCTAssertEqual(range, NSRange(location: 20, length: 5))
  }

  func testRejectsMissingAndAmbiguousText() {
    XCTAssertThrowsError(try TextSelectionMatcher.uniqueRange(
      in: "one two one",
      text: "one",
      prefix: nil,
      suffix: nil
    )) { error in
      XCTAssertEqual((error as? PilotRuntimeError)?.code, "ambiguous_target")
    }
    XCTAssertThrowsError(try TextSelectionMatcher.uniqueRange(
      in: "one two",
      text: "three",
      prefix: nil,
      suffix: nil
    )) { error in
      XCTAssertEqual((error as? PilotRuntimeError)?.code, "element_not_found")
    }
  }
}
