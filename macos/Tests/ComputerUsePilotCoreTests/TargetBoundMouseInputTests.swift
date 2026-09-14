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
    var postedButton: CGMouseButton?
    var restoredPoint: CGPoint?
    let input = TargetBoundMouseInput(
      isTargetFocused: { $0 == 42 },
      currentPointerLocation: { CGPoint(x: 740, y: 520) },
      postClicks: { point, clickCount, button in
        postedPoint = point
        postedClickCount = clickCount
        postedButton = button
      },
      restorePointerLocation: { restoredPoint = $0 }
    )

    try input.click(at: CGPoint(x: 28, y: 394), clickCount: 2, targetPID: 42)

    XCTAssertEqual(postedPoint, CGPoint(x: 28, y: 394))
    XCTAssertEqual(postedClickCount, 2)
    XCTAssertEqual(postedButton, .left)
    XCTAssertEqual(restoredPoint, CGPoint(x: 740, y: 520))
  }

  func testRefusesToClickWhenTargetLostFocus() {
    var didPost = false
    let input = TargetBoundMouseInput(
      isTargetFocused: { _ in false },
      currentPointerLocation: { CGPoint(x: 740, y: 520) },
      postClicks: { _, _, _ in didPost = true },
      restorePointerLocation: { _ in }
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
      restorePointerLocation: { _ in }
    )

    try input.click(at: .zero, clickCount: 1, button: .right, targetPID: 42)

    XCTAssertEqual(postedButton, .right)
  }

}
