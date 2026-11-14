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

  private typealias MainConnectionFunction = @convention(c) () -> UInt32
  private typealias WindowOwnerFunction = @convention(c) (UInt32, UInt32, UnsafeMutablePointer<UInt32>) -> Int32
  private typealias ConnectionPSNFunction = @convention(c) (UInt32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
  private typealias ProcessPIDFunction = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<pid_t>) -> Int32

  private static func skyLightSymbol(_ name: String) -> UnsafeMutableRawPointer? {
    dlsym(dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY), name)
  }
  private static let mainConnection: MainConnectionFunction? = skyLightSymbol("SLSMainConnectionID")
    .map { unsafeBitCast($0, to: MainConnectionFunction.self) }
  private static let windowOwner: WindowOwnerFunction? = skyLightSymbol("SLSGetWindowOwner")
    .map { unsafeBitCast($0, to: WindowOwnerFunction.self) }
  private static let connectionPSN: ConnectionPSNFunction? = skyLightSymbol("SLSGetConnectionPSN")
    .map { unsafeBitCast($0, to: ConnectionPSNFunction.self) }
  private static let processPID: ProcessPIDFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessPID")
    .map { unsafeBitCast($0, to: ProcessPIDFunction.self) }

  /// The process WindowServer says draws the element's window. Remote views
  /// (sandboxed Open/Save panels) are drawn by a service, not the app whose
  /// accessibility tree exposes them, and the public window list omits them.
  static func ownerPID(of element: AXUIElement) -> pid_t? {
    guard let windowID = windowID(of: element), let mainConnection, let windowOwner,
      let connectionPSN, let processPID else { return nil }
    var connection: UInt32 = 0
    var psn = ProcessSerialNumber()
    var pid: pid_t = 0
    guard windowOwner(mainConnection(), windowID, &connection) == 0, connection != 0,
      connectionPSN(connection, &psn) == 0, processPID(&psn, &pid) == 0, pid > 0 else { return nil }
    return pid
  }

  /// Without this, a click on an inactive app makes AppKit activate it.
  static func activationEvent(windowID: CGWindowID) -> CGEvent? {
    NSEvent.otherEvent(with: .appKitDefined, location: .zero,
      modifierFlags: NSEvent.ModifierFlags(rawValue: 0xC0000), timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: Int(windowID), context: nil, subtype: NSEvent.EventSubtype.applicationActivated.rawValue,
      data1: 0, data2: 0)?.cgEvent
  }

  private typealias SetWindowLocationFunction = @convention(c) (CGEvent, CGPoint) -> Void
  private static let setWindowLocation: SetWindowLocationFunction? =
    (dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation") ?? skyLightSymbol("CGEventSetWindowLocation"))
      .map { unsafeBitCast($0, to: SetWindowLocationFunction.self) }

  /// macOS 27 hit-tests a pid-routed click at its window-location stamp, read
  /// as a window-local point from the top-left; earlier releases expected the
  /// screen point there.
  static func windowLocation(of point: CGPoint, inWindowBounds bounds: CGRect, osMajorVersion: Int) -> CGPoint {
    osMajorVersion >= 27 ? CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY) : point
  }

  private static func windowBounds(_ windowID: CGWindowID) -> CGRect? {
    guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]])?.first,
      let dictionary = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
    var bounds = CGRect.zero
    return CGRectMakeWithDictionaryRepresentation(dictionary as CFDictionary, &bounds) ? bounds : nil
  }

  /// AppKit routes pid-targeted mouse events by their window number, not by
  /// what is on screen under the shared pointer.
  static func clickEvents(at point: CGPoint, windowID: CGWindowID) -> [CGEvent] {
    let stamp = windowBounds(windowID).map {
      windowLocation(of: point, inWindowBounds: $0, osMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
    return [NSEvent.EventType.leftMouseDown, .leftMouseUp].compactMap { type in
      guard let event = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: Int(windowID), context: nil,
        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)?.cgEvent else { return nil }
      event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
      event.setIntegerValueField(.mouseEventSubtype, value: 3)
      event.setIntegerValueField(windowUnderPointerField, value: Int64(windowID))
      event.setIntegerValueField(windowThatCanHandleEventField, value: Int64(windowID))
      event.location = point
      if let stamp, let setWindowLocation { setWindowLocation(event, stamp) }
      return event
    }
  }

  private typealias FrontProcessFunction = @convention(c) (UnsafeMutableRawPointer) -> Int32
  private typealias SetFrontProcessFunction = @convention(c) (UnsafeRawPointer, UInt32, UInt32) -> Int32
  private typealias PostEventRecordFunction = @convention(c) (UnsafeRawPointer, UnsafeRawPointer) -> Int32
  private typealias ProcessForPIDFunction = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32

  private static let frontProcess: FrontProcessFunction? = skyLightSymbol("_SLPSGetFrontProcess")
    .map { unsafeBitCast($0, to: FrontProcessFunction.self) }
  private static let setFrontProcess: SetFrontProcessFunction? = skyLightSymbol("_SLPSSetFrontProcessWithOptions")
    .map { unsafeBitCast($0, to: SetFrontProcessFunction.self) }
  private static let postEventRecord: PostEventRecordFunction? = skyLightSymbol("SLPSPostEventRecordTo")
    .map { unsafeBitCast($0, to: PostEventRecordFunction.self) }
  private static let processForPID: ProcessForPIDFunction? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID")
    .map { unsafeBitCast($0, to: ProcessForPIDFunction.self) }

  /// WindowServer's front process, read directly: NSWorkspace lags behind.
  static func frontPID() -> pid_t? {
    guard let frontProcess, let processPID else { return nil }
    var psn = ProcessSerialNumber()
    var pid: pid_t = 0
    guard frontProcess(&psn) == 0, processPID(&psn, &pid) == 0 else { return nil }
    return pid
  }

  /// Hand the front process and key window straight back to the user's app.
  private static func returnFront(to pid: pid_t, window: CGWindowID) {
    guard let setFrontProcess, let postEventRecord, let processForPID else { return }
    var psn = ProcessSerialNumber()
    guard processForPID(pid, &psn) == 0 else { return }
    _ = setFrontProcess(&psn, window, 0x200)
    for kind: UInt8 in [0x01, 0x02] {
      var record = [UInt8](repeating: 0, count: 0xF8)
      record[0x04] = 0xF8
      record[0x08] = kind
      record[0x3A] = 0x10
      withUnsafeBytes(of: window.littleEndian) { for (offset, byte) in $0.enumerated() { record[0x3C + offset] = byte } }
      for offset in 0x20..<0x30 { record[offset] = 0xFF }
      _ = postEventRecord(&psn, record)
    }
  }

  /// A remote Open/Save panel takes keyboard focus only from a click, and the
  /// panel service answers that click by activating its host app. Click one
  /// of the panel's labels, then give the front process back to the app the
  /// user was in before it can repaint (about 40 ms).
  static func focusRemotePanel(panelPID: pid_t, windowID: CGWindowID, at point: CGPoint) {
    let front = FrontSnapshot.capture()
    for event in clickEvents(at: point, windowID: windowID) {
      event.postToPid(panelPID)
      usleep(20_000)
    }
    for _ in 0..<60 {
      if front.restoreIfTaken() { return }
      usleep(5_000)
    }
  }

  /// The app and window the user is in, to hand the front back to them if a
  /// background action makes another app frontmost.
  final class FrontSnapshot {
    let pid: pid_t?
    let window: CGWindowID?
    let windowElement: AXUIElement?
    let wasOnTop: Bool
    private var raisedAt: Date?

    init(pid: pid_t?, window: CGWindowID?, windowElement: AXUIElement?, wasOnTop: Bool) {
      self.pid = pid
      self.window = window
      self.windowElement = windowElement
      self.wasOnTop = wasOnTop
    }

    static func capture() -> FrontSnapshot {
      let pid = SyntheticAppFocus.frontPID()
      let element = pid.flatMap { pid -> AXUIElement? in
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &focused) == .success,
          let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
      }
      let window = element.flatMap { SyntheticAppFocus.windowID(of: $0) }
      return FrontSnapshot(pid: pid, window: window, windowElement: element,
        wasOnTop: window != nil && onScreenOrder().first == window)
    }

    /// Whether the user's window, on top before, now has another window above it.
    static func windowCovered(window: CGWindowID, wasOnTop: Bool, order: [CGWindowID]) -> Bool {
      wasOnTop && order.first != window
    }

    /// Normal-level on-screen windows, front to back.
    private static func onScreenOrder() -> [CGWindowID] {
      (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    /// Restores now and once more after window ordering has settled.
    @MainActor
    func restoreSettled() {
      restoreIfTaken()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
      restoreIfTaken()
    }

    /// Hands the front back if another app took it, and raises the user's
    /// window back if a background app's menu ordered its window above it.
    @discardableResult
    func restoreIfTaken() -> Bool {
      guard let pid, let window else { return false }
      if let front = SyntheticAppFocus.frontPID(), front != pid {
        SyntheticAppFocus.returnFront(to: pid, window: window)
        return true
      }
      // The user's app handles an AXRaise on its own schedule; ask once and
      // let it land rather than queueing more requests behind it.
      if Self.windowCovered(window: window, wasOnTop: wasOnTop, order: Self.onScreenOrder()), let windowElement,
        raisedAt.map({ Date().timeIntervalSince($0) > 0.15 }) ?? true {
        raisedAt = Date()
        _ = AXUIElementPerformAction(windowElement, kAXRaiseAction as CFString)
        return true
      }
      return false
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
