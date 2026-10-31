import CoreGraphics
import XCTest
@testable import ComputerUsePilotCore

final class TargetBoundMouseInputTests: XCTestCase {
  // Failure modes: accidental physical input, clicks before movement finishes,
  // returning the pointer to its original position, and input after focus loss.
  func testPhysicalClickIsOptIn() throws {
    XCTAssertFalse(physicalClickRequested([:]))
    XCTAssertFalse(physicalClickRequested(["physical": .bool(false)]))
    XCTAssertTrue(physicalClickRequested(["physical": .bool(true)]))
    XCTAssertFalse(physicalClickRequested(["recording": .bool(true)]))
    XCTAssertThrowsError(try PilotArguments.validate(command: "click", arguments: ["recording": .bool(true)]))
    XCTAssertThrowsError(try PilotArguments.validate(command: "click", arguments: ["recording": .string("true")]))
  }

  func testRefusesToMoveOrClickWhenTargetLostFocus() {
    var didPost = false
    let input = TargetBoundMouseInput(
      isTargetFocused: { _ in false },
      currentPointerLocation: { CGPoint(x: 740, y: 520) },
      postClicks: { _, _, _ in didPost = true },
      movePointer: { _ in XCTFail("Must not move the pointer after losing focus") },
      movementPause: {}
    )

    XCTAssertThrowsError(
      try input.click(at: CGPoint(x: 28, y: 394), clickCount: 1, targetPID: 42)
    ) { error in
      XCTAssertEqual(error as? TargetBoundMouseInputError, .targetLostFocus)
    }
    XCTAssertFalse(didPost)
  }

  func testForwardsSecondaryMouseButton() throws {
    var postedButton: CGMouseButton?
    let input = TargetBoundMouseInput(
      isTargetFocused: { _ in true },
      currentPointerLocation: { .zero },
      postClicks: { _, _, button in postedButton = button },
      movePointer: { _ in },
      movementPause: {}
    )

    try input.click(at: .zero, clickCount: 1, button: .right, targetPID: 42)

    XCTAssertEqual(postedButton, .right)
  }

  func testPhysicalClickMovesTheRealPointerBeforeClickingAndLeavesItAtTheTarget() throws {
    var pointer = CGPoint(x: 100, y: 200)
    let target = CGPoint(x: 500, y: 400)
    var movements: [CGPoint] = []
    var clicked = false
    let input = TargetBoundMouseInput(
      isTargetFocused: { $0 == 42 },
      currentPointerLocation: { pointer },
      postClicks: { point, count, button in
        XCTAssertEqual(pointer, target)
        XCTAssertEqual(point, target)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(button, .left)
        clicked = true
      },
      movePointer: { pointer = $0; movements.append($0) },
      movementPause: {}
    )

    try input.click(at: target, clickCount: 2, targetPID: 42)

    XCTAssertTrue(clicked)
    XCTAssertEqual(pointer, target)
    XCTAssertGreaterThan(movements.count, 1)
    XCTAssertNotEqual(movements.first, target)
    XCTAssertTrue(zip(movements, movements.dropFirst()).allSatisfy { $0.x <= $1.x && $0.y <= $1.y })
  }

  func testPhysicalClickStopsBeforeClickingIfFocusIsLostDuringMovement() {
    // Cover both interrupted travel and loss of focus immediately before the click.
    for lossAfter in [1, 20] {
      var focused = true
      var clicked = false
      var movements = 0
      let input = TargetBoundMouseInput(
        isTargetFocused: { _ in focused },
        currentPointerLocation: { .zero },
        postClicks: { _, _, _ in clicked = true },
        movePointer: { _ in
          movements += 1
          if movements == lossAfter { focused = false }
        },
        movementPause: {}
      )

      XCTAssertThrowsError(try input.click(at: CGPoint(x: 500, y: 400), clickCount: 1, targetPID: 42)) {
        XCTAssertEqual($0 as? TargetBoundMouseInputError, .targetLostFocus)
      }
      XCTAssertEqual(movements, lossAfter)
      XCTAssertFalse(clicked)
    }
  }
}
