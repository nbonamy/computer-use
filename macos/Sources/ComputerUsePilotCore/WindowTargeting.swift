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
  private let backgroundFocuser: ((AXUIElement, AXUIElement) -> Void)?
  private let windowOwner: (AXUIElement) -> pid_t?
  private let focusPollInterval: TimeInterval

  init(attributeReader: ((AXUIElement, String) -> CFTypeRef?)? = nil,
       focusRequester: ((AXUIElement) -> Void)? = nil,
       raiseRequester: ((AXUIElement) -> Void)? = nil,
       backgroundFocuser: ((AXUIElement, AXUIElement) -> Void)? = nil,
       windowOwner: @escaping (AXUIElement) -> pid_t? = SyntheticAppFocus.ownerPID(of:),
       focusPollInterval: TimeInterval = 0.05) {
    self.attributeReader = attributeReader
    self.focusRequester = focusRequester
    self.raiseRequester = raiseRequester
    self.backgroundFocuser = backgroundFocuser
    self.windowOwner = windowOwner
    self.focusPollInterval = focusPollInterval
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
    keyboardWindow(window, app: app) != nil
  }

  /// The process that receives the selected window's keyboard input, or nil
  /// when the window is not the app's keyboard target. A sandboxed Open/Save
  /// panel is an empty sheet in the app; its controls are drawn, and its keys
  /// handled, by a system service. Keys sent to the app beep there.
  func keyboardProcess(_ window: AXUIElement, app: AXUIElement, appPID: pid_t) -> pid_t? {
    guard let target = keyboardWindow(window, app: app) else { return nil }
    guard attribute(target, kAXRoleAttribute) as? String == kAXSheetRole else { return appPID }
    var queue = attribute(target, kAXChildrenAttribute) as? [AXUIElement] ?? []
    var visited = 0
    while !queue.isEmpty, visited < 200 {
      let element = queue.removeFirst()
      visited += 1
      if let owner = windowOwner(element), owner != appPID { return owner }
      queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return appPID
  }

  /// A freshly opened remote panel holds no keyboard focus, so its keys go
  /// nowhere. Returns one of the panel's labels to click (a click on a label
  /// focuses the panel without selecting anything), or nil when the panel
  /// already has a focused element.
  func remotePanelFocusTarget(_ window: AXUIElement, app: AXUIElement, panelPID: pid_t) -> AXUIElement? {
    guard let sheet = keyboardWindow(window, app: app),
      attribute(sheet, kAXRoleAttribute) as? String == kAXSheetRole else { return nil }
    if let focused = elementAttribute(app, kAXFocusedUIElementAttribute), contains(focused, window: sheet) { return nil }
    var queue = attribute(sheet, kAXChildrenAttribute) as? [AXUIElement] ?? []
    var visited = 0
    while !queue.isEmpty, visited < 300 {
      let element = queue.removeFirst()
      visited += 1
      if attribute(element, kAXRoleAttribute) as? String == kAXStaticTextRole, windowOwner(element) == panelPID {
        return element
      }
      queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return nil
  }

  /// A background Open/Save panel drops Return as a default-button shortcut,
  /// and its AXDefaultButton stays empty. Returns the panel's enabled
  /// OKButton when Return would confirm it, nil when a text field has focus.
  func remotePanelDefaultButton(_ window: AXUIElement, app: AXUIElement) -> AXUIElement? {
    guard let sheet = keyboardWindow(window, app: app),
      attribute(sheet, kAXRoleAttribute) as? String == kAXSheetRole else { return nil }
    if let focused = elementAttribute(app, kAXFocusedUIElementAttribute),
      [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(attribute(focused, kAXRoleAttribute) as? String) {
      return nil
    }
    var queue = attribute(sheet, kAXChildrenAttribute) as? [AXUIElement] ?? []
    var visited = 0
    while !queue.isEmpty, visited < 300 {
      let element = queue.removeFirst()
      visited += 1
      if attribute(element, kAXRoleAttribute) as? String == kAXButtonRole,
        attribute(element, kAXIdentifierAttribute) as? String == "OKButton" {
        return (attribute(element, kAXEnabledAttribute) as? Bool) == true ? element : nil
      }
      queue.append(contentsOf: attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [])
    }
    return nil
  }

  /// Native file pickers and their Go To sheets can own keyboard focus while
  /// AXWindows still lists only their parent. Require a verified attachment;
  /// a different ordinary window or an unrelated sheet is never a substitute.
  func keyboardWindow(_ window: AXUIElement, app: AXUIElement) -> AXUIElement? {
    guard let focused = elementAttribute(app, kAXFocusedWindowAttribute) else { return nil }
    if CFEqual(focused, window) { return focused }
    guard attribute(focused, kAXRoleAttribute) as? String == kAXSheetRole,
      contains(focused, window: window) else { return nil }
    return focused
  }

  /// Background text preflight never selects, unminimizes, or raises a window.
  func requireTextTarget(_ window: AXUIElement, app: AXUIElement) throws {
    guard (attribute(window, kAXMinimizedAttribute) as? Bool) != true,
      isKeyboardTarget(window, app: app) else {
      throw PilotRuntimeError(code: "window_focus_failed",
        message: "Background text entry requires the selected window to be the app's existing keyboard target; no window focus was requested.")
    }
  }

  /// AXFocused writes and AXPress can activate an app, so focus moves through
  /// SyntheticAppFocus instead. Moves keyboard focus to an editable inside a background app without
  /// activating, raising, or unminimizing anything. Returns whether focus moved.
  @discardableResult
  func focusEditableInBackground(_ element: AXUIElement, window: AXUIElement, app: AXUIElement,
    clicking clickTarget: AXUIElement? = nil) throws -> Bool {
    if hasFocusedEditable(element, window: window, app: app) { return false }
    // A web <select> opens its menu (raising the browser) when clicked; a
    // click on its <label> focuses it without opening anything.
    let clickTarget = clickTarget ?? element
    guard (attribute(window, kAXMinimizedAttribute) as? Bool) != true else {
      throw PilotRuntimeError(code: "window_focus_failed",
        message: "Background text entry cannot target a minimized window; no focus was requested.")
    }
    // From a browser's address bar, the first click only hands the keyboard
    // to the web view, which restores its previously focused field.
    for _ in 0..<2 {
      if let backgroundFocuser {
        backgroundFocuser(window, element)
      } else {
        // A click outside the visible page cannot reach a field below the fold.
        if AXUIElementPerformAction(clickTarget, "AXScrollToVisible" as CFString) == .success {
          RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
        }
        if CFEqual(clickTarget, element), let frame = bounds(element) {
          SyntheticAppFocus.focus(element, in: window, at: CGPoint(x: frame.midX, y: frame.midY))
        } else if let label = bounds(clickTarget), let control = bounds(element) {
          guard let point = PopUpOptions.labelClickPoint(label: label, control: control) else {
            throw PilotRuntimeError(code: "element_focus_failed",
              message: "The control's label has no spot to click beside the control; nothing was clicked.")
          }
          SyntheticAppFocus.focus(clickTarget, in: window, at: point)
        }
      }
      for _ in 0..<10 {
        if hasFocusedEditable(element, window: window, app: app) { return true }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: focusPollInterval))
      }
    }
    throw PilotRuntimeError(code: "element_focus_failed",
      message: "The requested editable control did not take keyboard focus in the background; no text was sent.")
  }

  private func hasFocusedEditable(_ element: AXUIElement, window: AXUIElement, app: AXUIElement) -> Bool {
    guard isKeyboardTarget(window, app: app), let focused = elementAttribute(app, kAXFocusedUIElementAttribute) else { return false }
    return CFEqual(focused, element)
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
