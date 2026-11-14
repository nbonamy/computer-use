import ApplicationServices
import AppKit
import Foundation

enum TargetAccessibilityPreparation: Equatable {
  case enabled
  case failed
  case unsupported
}

final class TargetAccessibilitySupport {
  typealias ManualAccessibilitySetter = (_ processIdentifier: pid_t, _ enabled: Bool) -> AXError
  typealias EnhancedInterfaceSetter = (_ processIdentifier: pid_t, _ enabled: Bool) -> Bool

  private let setManualAccessibility: ManualAccessibilitySetter
  private let setEnhancedInterface: EnhancedInterfaceSetter
  private let isChromiumBrowser: (pid_t) -> Bool
  private let waitForTree: () -> Void
  private let waitForBrowserTree: () -> Void
  private var completedPreparations: [pid_t: TargetAccessibilityPreparation] = [:]
  private var enhancedProcesses: Set<pid_t> = []

  init(
    setManualAccessibility: @escaping ManualAccessibilitySetter = setManualAccessibilityOnApplication,
    setEnhancedInterface: @escaping EnhancedInterfaceSetter = setEnhancedInterfaceOnApplication,
    isChromiumBrowser: @escaping (pid_t) -> Bool = isChromiumBrowserProcess,
    waitForTree: @escaping () -> Void = { usleep(100_000) },
    waitForBrowserTree: @escaping () -> Void = { usleep(2_500_000) }
  ) {
    self.setManualAccessibility = setManualAccessibility
    self.setEnhancedInterface = setEnhancedInterface
    self.isChromiumBrowser = isChromiumBrowser
    self.waitForTree = waitForTree
    self.waitForBrowserTree = waitForBrowserTree
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
      // Recent Chrome ignores AXManualAccessibility and keeps web pages in a
      // reduced mode: no checked state, no slider range, no press actions.
      // The assistive-technology flag turns on the full tree after ~2 s.
      if isChromiumBrowser(processIdentifier), setEnhancedInterface(processIdentifier, true) {
        enhancedProcesses.insert(processIdentifier)
        waitForBrowserTree()
        completedPreparations[processIdentifier] = .enabled
        return .enabled
      }
      completedPreparations[processIdentifier] = .unsupported
      return .unsupported
    default:
      return .failed
    }
  }

  /// Hands browsers back their normal accessibility mode when the helper exits.
  func restore() {
    for pid in enhancedProcesses { _ = setEnhancedInterface(pid, false) }
    enhancedProcesses.removeAll()
  }

  static func isChromiumBundle(_ bundleURL: URL) -> Bool {
    let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
    return names.contains { $0.hasSuffix(" Framework.framework") } &&
      !names.contains("Electron Framework.framework")
  }
}

private func isChromiumBrowserProcess(_ processIdentifier: pid_t) -> Bool {
  guard let url = NSRunningApplication(processIdentifier: processIdentifier)?.bundleURL else { return false }
  return TargetAccessibilitySupport.isChromiumBundle(url)
}

private func setManualAccessibilityOnApplication(processIdentifier: pid_t, enabled: Bool) -> AXError {
  let application = AXUIElementCreateApplication(processIdentifier)
  return AXUIElementSetAttributeValue(
    application,
    "AXManualAccessibility" as CFString,
    (enabled ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef
  )
}

/// Chrome applies the flag but answers kAXErrorNotImplemented; read it back.
private func setEnhancedInterfaceOnApplication(processIdentifier: pid_t, enabled: Bool) -> Bool {
  let application = AXUIElementCreateApplication(processIdentifier)
  let name = "AXEnhancedUserInterface" as CFString
  _ = AXUIElementSetAttributeValue(application, name, (enabled ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
  var value: CFTypeRef?
  guard AXUIElementCopyAttributeValue(application, name, &value) == .success else { return false }
  return (value as? Bool) == enabled
}
