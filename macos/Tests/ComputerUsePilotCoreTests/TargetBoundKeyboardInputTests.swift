import Darwin
import XCTest

@testable import ComputerUsePilotCore

final class TargetBoundKeyboardInputTests: XCTestCase {
  func testRejectsTextBeforePostingWhenTargetDoesNotOwnFocus() {
    var posted: [Character] = []
    let input = TargetBoundKeyboardInput(
      isTargetFocused: { _ in false },
      pauseBetweenCharacters: {},
      postCharacter: { posted.append($0) }
    )

    XCTAssertThrowsError(try input.post("secret", targetPID: 42)) { error in
      XCTAssertEqual(error as? TargetBoundKeyboardInputError, .targetLostFocus)
    }
    XCTAssertTrue(posted.isEmpty)
  }

  func testStopsPostingWhenTargetLosesFocusMidString() {
    var focusChecks = 0
    var posted: [Character] = []
    let input = TargetBoundKeyboardInput(
      isTargetFocused: { _ in
        defer { focusChecks += 1 }
        return focusChecks == 0
      },
      pauseBetweenCharacters: {},
      postCharacter: { posted.append($0) }
    )

    XCTAssertThrowsError(try input.post("secret", targetPID: 42)) { error in
      XCTAssertEqual(error as? TargetBoundKeyboardInputError, .targetLostFocus)
    }
    XCTAssertEqual(posted, ["s"])
  }

  func testPostsAllTextWhileTargetOwnsFocus() throws {
    var posted: [Character] = []
    let input = TargetBoundKeyboardInput(
      isTargetFocused: { pid in pid == 42 },
      pauseBetweenCharacters: {},
      postCharacter: { posted.append($0) }
    )

    try input.post("hello", targetPID: 42)

    XCTAssertEqual(String(posted), "hello")
  }
}
