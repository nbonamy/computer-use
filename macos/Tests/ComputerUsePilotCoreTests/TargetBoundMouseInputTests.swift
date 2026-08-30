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
    let input = TargetBoundMouseInput(
      isTargetFocused: { $0 == 42 },
      postClicks: { point, clickCount in
        postedPoint = point
        postedClickCount = clickCount
      }
    )

    try input.click(at: CGPoint(x: 28, y: 394), clickCount: 2, targetPID: 42)

    XCTAssertEqual(postedPoint, CGPoint(x: 28, y: 394))
    XCTAssertEqual(postedClickCount, 2)
  }

  func testRefusesToClickWhenTargetLostFocus() {
    var didPost = false
    let input = TargetBoundMouseInput(
      isTargetFocused: { _ in false },
      postClicks: { _, _ in didPost = true }
    )

    XCTAssertThrowsError(
      try input.click(at: CGPoint(x: 28, y: 394), clickCount: 1, targetPID: 42)
    ) { error in
      XCTAssertEqual(error as? TargetBoundMouseInputError, .targetLostFocus)
    }
    XCTAssertFalse(didPost)
  }
}
