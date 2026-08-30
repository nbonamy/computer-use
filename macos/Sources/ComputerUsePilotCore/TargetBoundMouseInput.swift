import CoreGraphics
import Darwin

enum TargetBoundMouseInputError: Error, Equatable {
  case targetLostFocus
}

struct TargetBoundMouseInput {
  let isTargetFocused: (pid_t) -> Bool
  let postClicks: (CGPoint, Int) -> Void

  func click(at point: CGPoint, clickCount: Int, targetPID: pid_t) throws {
    guard isTargetFocused(targetPID) else {
      throw TargetBoundMouseInputError.targetLostFocus
    }
    postClicks(point, clickCount)
  }
}

func physicalClickRequested(_ arguments: [String: JSONValue]) -> Bool {
  arguments["physical"]?.boolValue == true
}
