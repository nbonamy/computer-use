import AppKit
import ApplicationServices

/// Session-local identity. Every resolution requires an explicit window ID.
final class WindowSelection<Element> {
  private var entries: [(id: Int, pid: pid_t, element: Element)] = []
  private let equal: (Element, Element) -> Bool

  init(equal: @escaping (Element, Element) -> Bool) { self.equal = equal }

  func id(for element: Element, pid: pid_t) -> Int {
    if let entry = entries.first(where: { $0.pid == pid && equal($0.element, element) }) {
      return entry.id
    }
    let id = entries.count + 1
    entries.append((id, pid, element))
    return id
  }

  func resolve(pid: pid_t, requested: Int, windows: [Element]) throws -> (id: Int, element: Element) {
    guard let entry = entries.first(where: { $0.id == requested && $0.pid == pid }),
          let live = windows.first(where: { equal($0, entry.element) }) else {
      throw PilotRuntimeError(code: "window_not_found", message: "Window \(requested) is unavailable for this app. Call list_windows and select a live window_id.")
    }
    return (requested, live)
  }
}

struct WindowCaptureTarget {
  let windowID: Int
  let title: String
  let bounds: CGRect

  func matches(title: String?, bounds: CGRect) -> Bool {
    self.title == (title ?? "") && abs(self.bounds.minX - bounds.minX) < 2
      && abs(self.bounds.minY - bounds.minY) < 2
      && abs(self.bounds.width - bounds.width) < 2
      && abs(self.bounds.height - bounds.height) < 2
  }
}

@MainActor
final class WindowTargeting {
  private let selection = WindowSelection<AXUIElement>(equal: { CFEqual($0, $1) })
  private let attributeReader: ((AXUIElement, String) -> CFTypeRef?)?
  private let focusRequester: ((AXUIElement) -> Void)?
  private let raiseRequester: ((AXUIElement) -> Void)?

  init(attributeReader: ((AXUIElement, String) -> CFTypeRef?)? = nil,
       focusRequester: ((AXUIElement) -> Void)? = nil,
       raiseRequester: ((AXUIElement) -> Void)? = nil) {
    self.attributeReader = attributeReader
    self.focusRequester = focusRequester
    self.raiseRequester = raiseRequester
  }

  func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    if let attributeReader { return attributeReader(element, name) }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
    guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
  }

  private func windows(_ app: AXUIElement) -> [AXUIElement] {
    attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
  }

  func resolve(app: AXUIElement, pid: pid_t, requested: Int) throws -> (id: Int, element: AXUIElement) {
    try selection.resolve(pid: pid, requested: requested, windows: windows(app))
  }

  func list(app: AXUIElement, pid: pid_t) -> [JSONValue] {
    let focused = elementAttribute(app, kAXFocusedWindowAttribute)
    return windows(app).map { window in
      let id = selection.id(for: window, pid: pid)
      var result = description(window, id: id).objectValue ?? [:]
      result["is_key"] = .bool(focused.map { CFEqual($0, window) } ?? false)
      result["is_minimized"] = .bool((attribute(window, kAXMinimizedAttribute) as? Bool) ?? false)
      return .object(result)
    }
  }

  func bounds(_ window: AXUIElement) -> CGRect? {
    guard let position = attribute(window, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
          let size = attribute(window, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    var dimensions = CGSize.zero
    guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
          AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
    return CGRect(origin: point, size: dimensions)
  }

  func description(_ window: AXUIElement, id: Int) -> JSONValue {
    var result: [String: JSONValue] = ["window_id": .number(Double(id)),
      "title": .string(attribute(window, kAXTitleAttribute) as? String ?? ""), "role": .string("AXWindow")]
    if let frame = bounds(window) {
      result["frame"] = .object(["x": .number(frame.minX), "y": .number(frame.minY),
        "width": .number(frame.width), "height": .number(frame.height)])
    }
    return .object(result)
  }

  func captureTarget(_ window: AXUIElement, id: Int) throws -> WindowCaptureTarget {
    guard let bounds = bounds(window) else {
      throw PilotRuntimeError(code: "window_not_found", message: "Selected window has no accessible bounds.")
    }
    return WindowCaptureTarget(windowID: id, title: attribute(window, kAXTitleAttribute) as? String ?? "", bounds: bounds)
  }

  func contains(_ element: AXUIElement, window: AXUIElement) -> Bool {
    if CFEqual(element, window) { return true }
    if let owner = elementAttribute(element, kAXWindowAttribute), CFEqual(owner, window) { return true }
    var current = element
    var visited: [AXUIElement] = []
    while let parent = elementAttribute(current, kAXParentAttribute) {
      if CFEqual(parent, window) { return true }
      if visited.contains(where: { CFEqual($0, parent) }) { break }
      visited.append(parent)
      current = parent
    }
    return false
  }

  func isKeyboardTarget(_ window: AXUIElement, app: AXUIElement) -> Bool {
    elementAttribute(app, kAXFocusedWindowAttribute).map { CFEqual($0, window) } ?? false
  }

  func focus(_ window: AXUIElement, app: AXUIElement, allowRaise: Bool = false) throws {
    if isKeyboardTarget(window, app: app) { return }
    if let focusRequester {
      focusRequester(window)
    } else {
      _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
      _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
      _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
    if allowRaise {
      if let raiseRequester { raiseRequester(window) }
      else { _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
    }
    for _ in 0..<10 {
      if isKeyboardTarget(window, app: app) { return }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    throw PilotRuntimeError(code: "window_focus_failed", message: "The selected window did not become the app's keyboard target; no input was sent.")
  }
}
