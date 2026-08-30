import CoreGraphics
import XCTest
@testable import ComputerUsePilotCore

final class TargetBoundMouseInputTests: XCTestCase {
  func testPhysicalClickIsOptIn() {
    XCTAssertFalse(physicalClickRequested([:]))
    XCTAssertFalse(physicalClickRequested(["physical": .bool(false)]))
    XCTAssertTrue(physicalClickRequested(["physical": .bool(true)]))
  }

  func testPostsRequestedClicksWhenTargetOwnsFocus() throws {
    var postedPoint: CGPoint?
    var postedClickCount: Int?
    var movedPoint: CGPoint?
    var restoredPoint: CGPoint?
    let input = TargetBoundMouseInput(
      isTargetFocused: { $0 == 42 },
      currentPointerLocation: { CGPoint(x: 740, y: 520) },
      postClicks: { point, clickCount in
        postedPoint = point
        postedClickCount = clickCount
      },
      movePointer: { movedPoint = $0 },
      restorePointerLocation: { restoredPoint = $0 }
    )

    try input.click(at: CGPoint(x: 28, y: 394), clickCount: 2, targetPID: 42)

    XCTAssertEqual(postedPoint, CGPoint(x: 28, y: 394))
    XCTAssertEqual(postedClickCount, 2)
    XCTAssertNil(movedPoint)
    XCTAssertEqual(restoredPoint, CGPoint(x: 740, y: 520))
  }

  func testMovesPointerWhenTargetOwnsFocusWithoutRestoringIt() throws {
    var movedPoint: CGPoint?
    var restoredPoint: CGPoint?
    let input = TargetBoundMouseInput(
      isTargetFocused: { $0 == 42 },
      currentPointerLocation: { CGPoint(x: 740, y: 520) },
      postClicks: { _, _ in },
      movePointer: { movedPoint = $0 },
      restorePointerLocation: { restoredPoint = $0 }
    )

    try input.move(to: CGPoint(x: 179, y: 16), targetPID: 42)

    XCTAssertEqual(movedPoint, CGPoint(x: 179, y: 16))
    XCTAssertNil(restoredPoint)
  }

  func testRefusesToClickWhenTargetLostFocus() {
    var didPost = false
    let input = TargetBoundMouseInput(
      isTargetFocused: { _ in false },
      currentPointerLocation: { CGPoint(x: 740, y: 520) },
      postClicks: { _, _ in didPost = true },
      movePointer: { _ in didPost = true },
      restorePointerLocation: { _ in }
    )

    XCTAssertThrowsError(
      try input.click(at: CGPoint(x: 28, y: 394), clickCount: 1, targetPID: 42)
    ) { error in
      XCTAssertEqual(error as? TargetBoundMouseInputError, .targetLostFocus)
    }
    XCTAssertFalse(didPost)
  }

  func testRefusesToMoveWhenTargetLostFocus() {
    var didMove = false
    let input = TargetBoundMouseInput(
      isTargetFocused: { _ in false },
      currentPointerLocation: { CGPoint(x: 740, y: 520) },
      postClicks: { _, _ in },
      movePointer: { _ in didMove = true },
      restorePointerLocation: { _ in }
    )

    XCTAssertThrowsError(
      try input.move(to: CGPoint(x: 179, y: 16), targetPID: 42)
    ) { error in
      XCTAssertEqual(error as? TargetBoundMouseInputError, .targetLostFocus)
    }
    XCTAssertFalse(didMove)
  }
}
