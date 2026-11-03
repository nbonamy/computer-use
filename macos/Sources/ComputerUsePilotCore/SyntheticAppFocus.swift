import AppKit
import ApplicationServices

/// Moves keyboard focus inside a background app without activating it. The app
/// is told it became active, then receives a click routed to the target window
/// through its own event queue. WindowServer's frontmost app and the user's
/// pointer are left untouched, so the user keeps working where they are.
enum SyntheticAppFocus {
  static let windowUnderPointerField = CGEventField(rawValue: 91)!
  static let windowThatCanHandleEventField = CGEventField(rawValue: 92)!

  private typealias GetWindowFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

  /// Private SPI, resolved at runtime so its removal only disables background
  /// focus instead of preventing the helper from launching.
  private static let getWindow: GetWindowFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
    .map { unsafeBitCast($0, to: GetWindowFunction.self) }

  static func windowID(of window: AXUIElement) -> CGWindowID? {
    var windowID: CGWindowID = 0
    guard let getWindow, getWindow(window, &windowID) == .success, windowID != 0 else { return nil }
    return windowID
  }

  /// Without this, a click on an inactive app makes AppKit activate it.
  static func activationEvent(windowID: CGWindowID) -> CGEvent? {
    NSEvent.otherEvent(with: .appKitDefined, location: .zero,
      modifierFlags: NSEvent.ModifierFlags(rawValue: 0xC0000), timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: Int(windowID), context: nil, subtype: NSEvent.EventSubtype.applicationActivated.rawValue,
      data1: 0, data2: 0)?.cgEvent
  }

  /// AppKit routes pid-targeted mouse events by their window number, not by
  /// what is on screen under the shared pointer.
  static func clickEvents(at point: CGPoint, windowID: CGWindowID) -> [CGEvent] {
    [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
      guard let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowID), context: nil,
        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)?.cgEvent else { return nil }
      event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
      event.setIntegerValueField(.mouseEventSubtype, value: 3)
      event.setIntegerValueField(windowUnderPointerField, value: Int64(windowID))
      event.setIntegerValueField(windowThatCanHandleEventField, value: Int64(windowID))
      event.location = point
      return event
    }
  }

  static func focus(_ element: AXUIElement, in window: AXUIElement, at point: CGPoint) {
    var pid: pid_t = 0
    guard AXUIElementGetPid(element, &pid) == .success, let windowID = windowID(of: window) else { return }
    activationEvent(windowID: windowID)?.postToPid(pid)
    for event in clickEvents(at: point, windowID: windowID) {
      event.postToPid(pid)
      usleep(30_000)
    }
  }
}
