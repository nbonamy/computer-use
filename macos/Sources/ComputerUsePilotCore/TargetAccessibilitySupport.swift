import ApplicationServices
import Foundation

enum TargetAccessibilityPreparation: Equatable {
  case enabled
  case failed
  case unsupported
}

final class TargetAccessibilitySupport {
  typealias ManualAccessibilitySetter = (_ processIdentifier: pid_t, _ enabled: Bool) -> AXError

  private let setManualAccessibility: ManualAccessibilitySetter
  private let waitForTree: () -> Void
  private var completedPreparations: [pid_t: TargetAccessibilityPreparation] = [:]

  init(
    setManualAccessibility: @escaping ManualAccessibilitySetter = setManualAccessibilityOnApplication,
    waitForTree: @escaping () -> Void = { usleep(100_000) }
  ) {
    self.setManualAccessibility = setManualAccessibility
    self.waitForTree = waitForTree
  }

  func prepare(processIdentifier: pid_t) -> TargetAccessibilityPreparation {
    if let preparation = completedPreparations[processIdentifier] {
      return preparation
    }

    let error = setManualAccessibility(processIdentifier, true)
    switch error {
    case .success:
      waitForTree()
      completedPreparations[processIdentifier] = .enabled
      return .enabled
    case .attributeUnsupported, .notImplemented:
      completedPreparations[processIdentifier] = .unsupported
      return .unsupported
    default:
      return .failed
    }
  }
}

private func setManualAccessibilityOnApplication(processIdentifier: pid_t, enabled: Bool) -> AXError {
  let application = AXUIElementCreateApplication(processIdentifier)
  return AXUIElementSetAttributeValue(
    application,
    "AXManualAccessibility" as CFString,
    (enabled ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
  )
}
