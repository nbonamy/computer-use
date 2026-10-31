import CoreGraphics
import Darwin

enum TargetBoundMouseInputError: Error, Equatable {
  case targetLostFocus
}

struct TargetBoundMouseInput {
  let isTargetFocused: (pid_t) -> Bool
  let currentPointerLocation: () -> CGPoint
  let postClicks: (CGPoint, Int, CGMouseButton) -> Void
  let movePointer: (CGPoint) -> Void
  var movementPause: () -> Void = { usleep(16_000) }

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
    for step in 1...20 {
      guard isTargetFocused(targetPID) else {
        throw TargetBoundMouseInputError.targetLostFocus
      }
      let progress = CGFloat(step) / 20
      let eased = progress * progress * (3 - 2 * progress)
      movePointer(CGPoint(
        x: pointerLocation.x + (point.x - pointerLocation.x) * eased,
        y: pointerLocation.y + (point.y - pointerLocation.y) * eased
      ))
      movementPause()
    }
    guard isTargetFocused(targetPID) else {
      throw TargetBoundMouseInputError.targetLostFocus
    }
    postClicks(point, clickCount, button)
  }

}

func physicalClickRequested(_ arguments: [String: JSONValue]) -> Bool {
  arguments["physical"]?.boolValue == true
}
