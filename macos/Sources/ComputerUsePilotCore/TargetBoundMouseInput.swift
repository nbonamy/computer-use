import CoreGraphics
import Darwin

enum TargetBoundMouseInputError: Error, Equatable {
  case targetLostFocus
}

struct TargetBoundMouseInput {
  let isTargetFocused: (pid_t) -> Bool
  let currentPointerLocation: () -> CGPoint
  let postClicks: (CGPoint, Int, CGMouseButton) -> Void
  let restorePointerLocation: (CGPoint) -> Void

  func click(
    at point: CGPoint,
    clickCount: Int,
    button: CGMouseButton = .left,
    targetPID: pid_t
  ) throws {
    guard isTargetFocused(targetPID) else {
      throw TargetBoundMouseInputError.targetLostFocus
    }
    let pointerLocation = currentPointerLocation()
    defer { restorePointerLocation(pointerLocation) }
    postClicks(point, clickCount, button)
  }

}

func physicalClickRequested(_ arguments: [String: JSONValue]) -> Bool {
  arguments["physical"]?.boolValue == true
}
