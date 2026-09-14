import AppKit
import ApplicationServices
import Foundation

private let compactAttributeCharacterLimit = 160

private struct InstalledApplication {
  let bundleIdentifier: String?
  let localizedName: String
  let path: String
}

private final class LaunchApplicationResult: @unchecked Sendable {
  private let lock = NSLock()
  private var app: NSRunningApplication?
  private var error: Error?

  func update(app: NSRunningApplication?, error: Error?) {
    lock.lock()
    self.app = app
    self.error = error
    lock.unlock()
  }

  func values() -> (app: NSRunningApplication?, error: Error?) {
    lock.lock()
    defer { lock.unlock() }
    return (app, error)
  }
}

@MainActor
public final class AccessibilityPilot {
  private let cursorOverlay: any ComputerUseCursorPresenting
  private let initialCursorPresenter: () -> Void
  private let screenCapturer: ScreenCapturing
  private let targetAccessibilitySupport: TargetAccessibilitySupport
  private let stateHistory = AccessibilityStateHistory()
  private let windowTargets: WindowTargeting
  private var elementBuckets: [CFHashCode: [(index: Int, element: AXUIElement)]] = [:]
  private var latestObservedElementIDsByPID: [pid_t: Set<Int>] = [:]
  private var nextElementIndex = 0
  private var pendingSettleAtByPID: [pid_t: Date] = [:]
  private var didPresentInitialCursor = false

  public init(cursorOverlay: ComputerUseCursorOverlay = ComputerUseCursorOverlay()) {
    self.cursorOverlay = cursorOverlay
    self.initialCursorPresenter = { cursorOverlay.showAtMainScreenCenter() }
    self.screenCapturer = MacScreenCapturer()
    self.windowTargets = WindowTargeting()
    self.targetAccessibilitySupport = TargetAccessibilitySupport()
  }

  init(
    cursorOverlay: any ComputerUseCursorPresenting = ComputerUseCursorOverlay(),
    initialCursorPresenter: @escaping () -> Void,
    screenCapturer: ScreenCapturing = MacScreenCapturer(),
    targetAccessibilitySupport: TargetAccessibilitySupport = TargetAccessibilitySupport(),
    windowTargets: WindowTargeting = WindowTargeting()
  ) {
    self.cursorOverlay = cursorOverlay
    self.initialCursorPresenter = initialCursorPresenter
    self.screenCapturer = screenCapturer
    self.windowTargets = windowTargets
    self.targetAccessibilitySupport = targetAccessibilitySupport
  }

  public func handle(_ request: PilotRequest) -> PilotResponse {
    do {
      if requiresWindowID(request) {
        _ = try requiredWindowID(request.arguments)
      }
      try PilotArguments.validate(command: request.command, arguments: request.arguments)
    } catch let error as PilotRuntimeError {
      return .failure(id: request.id, code: error.code, message: error.message)
    } catch {
      return .failure(id: request.id, code: "invalid_request", message: error.localizedDescription)
    }
    if request.command != "screenshot" && request.arguments["showCursor"]?.boolValue != false {
      presentInitialCursorIfNeeded()
    }
    switch request.command {
    case "ping":
      return .success(id: request.id, result: .object(["success": .bool(true)]))
    case "status":
      return .success(id: request.id, result: status())
    case "request_accessibility":
      return .success(id: request.id, result: requestAccessibility(arguments: request.arguments))
    case "request_screen_capture":
      return .success(id: request.id, result: requestScreenCapture())
    case "screenshot":
      return runtimeGuard(id: request.id) { try screenshot(arguments: request.arguments) }
    case "list_apps":
      return .success(id: request.id, result: listApps())
    case "list_windows":
      return accessibilityGuard(id: request.id) { try listWindows(arguments: request.arguments) }
    case "find_apps":
      return runtimeGuard(id: request.id) { try findApps(arguments: request.arguments) }
    case "launch_app":
      return runtimeGuard(id: request.id) { try launchApp(arguments: request.arguments) }
    case "focus_app":
      return .success(id: request.id, result: focusApp(arguments: request.arguments))
    case "get_app_state":
      return accessibilityGuard(id: request.id) { try getAppState(arguments: request.arguments) }
    case "click":
      return actionGuard(id: request.id, arguments: request.arguments) { try click(arguments: request.arguments) }
    case "dismiss":
      return actionGuard(id: request.id, arguments: request.arguments) { try dismiss(arguments: request.arguments) }
    case "type_text":
      return actionGuard(id: request.id, arguments: request.arguments) { try typeText(arguments: request.arguments) }
    case "press_key":
      return actionGuard(id: request.id, arguments: request.arguments) { try pressKey(arguments: request.arguments) }
    case "drag":
      return actionGuard(id: request.id, arguments: request.arguments) { try drag(arguments: request.arguments) }
    case "perform_secondary_action":
      return actionGuard(id: request.id, arguments: request.arguments) { try performSecondaryAction(arguments: request.arguments) }
    case "paste":
      return actionGuard(id: request.id, arguments: request.arguments) { try paste(arguments: request.arguments) }
    case "select_text":
      return actionGuard(id: request.id, arguments: request.arguments) { try selectText(arguments: request.arguments) }
    case "set_value":
      return actionGuard(id: request.id, arguments: request.arguments) { try setValue(arguments: request.arguments) }
    case "scroll":
      return actionGuard(id: request.id, arguments: request.arguments) { try scroll(arguments: request.arguments) }
    default:
      return .failure(id: request.id, code: "unknown_command", message: "Unknown command \(request.command).")
    }
  }

  private func presentInitialCursorIfNeeded() {
    guard !didPresentInitialCursor else {
      return
    }
    didPresentInitialCursor = true
    initialCursorPresenter()
  }

  private func requiresWindowID(_ request: PilotRequest) -> Bool {
    switch request.command {
    case "get_app_state":
      return request.arguments["accessibilityScope"]?.stringValue != "menu_bar"
    case "screenshot":
      return (request.arguments["scope"]?.stringValue ?? "window") == "window"
    case "focus_app", "click", "dismiss", "type_text", "press_key", "drag",
         "perform_secondary_action", "paste", "select_text", "set_value", "scroll":
      return true
    default:
      return false
    }
  }

  private func requiredWindowID(_ arguments: [String: JSONValue]) throws -> Int {
    guard let id = try optionalIntegerArgument(arguments, "window_id", minimum: 1) else {
      throw PilotRuntimeError(code: "invalid_request", message: "window_id is required. Call list_windows for the target app first.")
    }
    return id
  }

  private func accessibilityGuard(id: String?, operation: () throws -> JSONValue) -> PilotResponse {
    guard AXIsProcessTrusted() else {
      return .failure(
        id: id,
        code: "accessibility_not_granted",
        message: "Computer Use does not have macOS Accessibility permission."
      )
    }

    do {
      return .success(id: id, result: try operation())
    } catch let error as PilotRuntimeError {
      return .failure(id: id, code: error.code, message: error.message)
    } catch {
      return .failure(id: id, code: "client_error", message: error.localizedDescription)
    }
  }

  private func runtimeGuard(id: String?, operation: () throws -> JSONValue) -> PilotResponse {
    do {
      return .success(id: id, result: try operation())
    } catch let error as PilotRuntimeError {
      return .failure(id: id, code: error.code, message: error.message)
    } catch {
      return .failure(id: id, code: "client_error", message: error.localizedDescription)
    }
  }

  private func actionGuard(
    id: String?,
    arguments: [String: JSONValue],
    operation: () throws -> JSONValue
  ) -> PilotResponse {
    accessibilityGuard(id: id) {
      _ = try selectedWindow(arguments: arguments)
      if arguments["accessibilityScope"]?.stringValue == "menu_bar" {
        _ = try prepareKeyboardTarget(arguments: arguments)
      }
      let result = try operation()
      if let app = try? runningApplication(arguments: arguments) {
        pendingSettleAtByPID[app.processIdentifier] = Date()
      }
      return result
    }
  }

  private func status() -> JSONValue {
    .object([
      "accessibilityTrusted": .bool(AXIsProcessTrusted()),
      "screenCaptureTrusted": .bool(screenCapturer.isTrusted),
      "platform": .string("macos"),
      "version": .string("2.0.2"),
      "success": .bool(true)
    ])
  }

  private func requestScreenCapture() -> JSONValue {
    .object([
      "screenCaptureTrusted": .bool(screenCapturer.requestAccess()),
      "success": .bool(true)
    ])
  }

  private func screenshot(arguments: [String: JSONValue]) throws -> JSONValue {
    let shouldRestoreCursor = cursorOverlay.hideForCapture()
    defer { cursorOverlay.restoreAfterCapture(shouldRestoreCursor) }
    let scope = arguments["scope"]?.stringValue ?? "window"
    switch scope {
    case "window":
      let app = try runningApplication(arguments: arguments)
      let window = try selectedWindow(arguments: arguments)
      return try screenCapturer.captureWindow(application: app,
        target: windowTargets.captureTarget(window.element, id: window.id))
    case "screen":
      return try screenCapturer.captureScreen(displayID: try displayIdentifierArgument(arguments))
    default:
      throw PilotRuntimeError(code: "invalid_request", message: "scope must be window or screen.")
    }
  }

  private func displayIdentifierArgument(_ arguments: [String: JSONValue]) throws -> CGDirectDisplayID? {
    guard let rawDisplayID = arguments["displayId"] else {
      return nil
    }
    guard let value = rawDisplayID.intValue,
          let displayID = CGDirectDisplayID(exactly: value),
          displayID > 0 else {
      throw PilotRuntimeError(code: "invalid_request", message: "displayId must be a positive display identifier.")
    }
    return displayID
  }

  private func requestAccessibility(arguments: [String: JSONValue]) -> JSONValue {
    let prompt = arguments["prompt"]?.boolValue ?? true
    let openSettings = arguments["openSettings"]?.boolValue ?? true

    if prompt {
      let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
      _ = AXIsProcessTrustedWithOptions(options)
    }

    let openedSettings = openSettings
      ? NSWorkspace.shared.open(accessibilitySettingsURL())
      : false

    return .object([
      "accessibilityTrusted": .bool(AXIsProcessTrusted()),
      "openedSettings": .bool(openedSettings),
      "promptRequested": .bool(prompt),
      "requestingProcess": requestingProcess(),
      "success": .bool(true)
    ])
  }

  private func accessibilitySettingsURL() -> URL {
    if #available(macOS 13.0, *) {
      return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    }
    return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
  }

  private func requestingProcess() -> JSONValue {
    let bundle = Bundle.main
    return .object([
      "bundleIdentifier": .from(bundle.bundleIdentifier),
      "executablePath": .from(bundle.executablePath),
      "processName": .string(ProcessInfo.processInfo.processName)
    ])
  }

  private func listApps() -> JSONValue {
    let apps = NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular || $0.activationPolicy == .accessory }
      .map { app in
        JSONValue.object([
          "active": .bool(app.isActive),
          "bundleIdentifier": .from(app.bundleIdentifier),
          "localizedName": .from(app.localizedName),
          "pid": .number(Double(app.processIdentifier)),
          "terminated": .bool(app.isTerminated)
        ])
      }
    return .object(["apps": .array(apps), "success": .bool(true)])
  }

  private func listWindows(arguments: [String: JSONValue]) throws -> JSONValue {
    let app = try runningApplication(arguments: arguments)
    let root = preparedRootElement(processIdentifier: app.processIdentifier)
    return .object(["success": .bool(true), "app": runningApplicationDescription(app),
      "windows": .array(windowTargets.list(app: root, pid: app.processIdentifier))])
  }

  private func selectedWindow(arguments: [String: JSONValue]) throws -> (id: Int, element: AXUIElement) {
    let app = try runningApplication(arguments: arguments)
    let requested = try requiredWindowID(arguments)
    return try windowTargets.resolve(app: preparedRootElement(processIdentifier: app.processIdentifier),
      pid: app.processIdentifier, requested: requested)
  }

  private func validateWindow(_ element: AXUIElement, arguments: [String: JSONValue]) throws {
    if arguments["accessibilityScope"]?.stringValue == "menu_bar" { return }
    let window = try selectedWindow(arguments: arguments)
    guard windowTargets.contains(element, window: window.element) else {
      throw PilotRuntimeError(code: "window_mismatch", message: "Element does not belong to the selected window. Observe the intended window_id first.")
    }
  }

  private func findApps(arguments: [String: JSONValue]) throws -> JSONValue {
    let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    let bundleIdentifier = arguments["bundleIdentifier"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    let maxResults = try optionalIntegerArgument(arguments, "maxResults", minimum: 1)

    var apps = installedApplications(bundleIdentifier: bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil)

    if let query, !query.isEmpty {
      apps = apps.filter { app in
        app.localizedName.localizedCaseInsensitiveContains(query) ||
          app.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true ||
          app.path.localizedCaseInsensitiveContains(query)
      }
    }

    apps.sort { lhs, rhs in
      lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
    }

    if let maxResults, apps.count > maxResults {
      apps = Array(apps.prefix(maxResults))
    }

    return .object([
      "apps": .array(apps.map(installedApplicationDescription)),
      "success": .bool(true)
    ])
  }

  private func launchApp(arguments: [String: JSONValue]) throws -> JSONValue {
    let bundleIdentifier = arguments["bundleIdentifier"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    let rawPath = arguments["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard bundleIdentifier?.isEmpty == false || rawPath?.isEmpty == false else {
      throw PilotRuntimeError(code: "invalid_request", message: "launch_app requires bundleIdentifier or path.")
    }

    let appURL: URL
    if let rawPath, !rawPath.isEmpty {
      appURL = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
    } else {
      guard let bundleIdentifier,
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
        throw PilotRuntimeError(code: "app_not_found", message: "Could not find installed app \(bundleIdentifier ?? "").")
      }
      appURL = url
    }

    guard FileManager.default.fileExists(atPath: appURL.path) else {
      throw PilotRuntimeError(code: "app_not_found", message: "Could not find app at \(appURL.path).")
    }

    let activate = arguments["activate"]?.boolValue ?? true
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = activate
    configuration.addsToRecentItems = true

    let launchResult = LaunchApplicationResult()
    let semaphore = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
      launchResult.update(app: app, error: error)
      semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + 10)

    let (launchedApp, launchError) = launchResult.values()
    if let launchError {
      throw PilotRuntimeError(code: "client_error", message: launchError.localizedDescription)
    }

    let app = launchedApp ?? runningApplication(bundleIdentifier: bundleIdentifier, path: appURL.path)
    guard let app else {
      throw PilotRuntimeError(code: "app_not_found", message: "Launched app did not appear in running applications.")
    }
    if activate {
      waitForActivation(app)
    }

    return .object([
      "app": runningApplicationDescription(app),
      "success": .bool(true)
    ])
  }

  private func focusApp(arguments: [String: JSONValue]) -> JSONValue {
    do {
      guard arguments["app"] != nil || arguments["pid"] != nil else {
        return .object([
          "error": .string("focus_app requires app or pid."),
          "success": .bool(false)
        ])
      }
      let app = try prepareKeyboardTarget(arguments: arguments, foreground: true)
      let activated = app.isActive
      return .object([
        "activated": .bool(activated),
        "app": .object([
          "active": .bool(app.isActive),
          "bundleIdentifier": .from(app.bundleIdentifier),
          "localizedName": .from(app.localizedName),
          "pid": .number(Double(app.processIdentifier))
        ]),
        "success": .bool(true)
      ])
    } catch let error as PilotRuntimeError {
      return .object([
        "error": .string(error.message),
        "errorCode": .string(error.code),
        "success": .bool(false)
      ])
    } catch {
      return .object([
        "error": .string(error.localizedDescription),
        "errorCode": .string("client_error"),
        "success": .bool(false)
      ])
    }
  }

  private func getAppState(arguments: [String: JSONValue]) throws -> JSONValue {
    let app = try runningApplication(arguments: arguments)
    let appRoot = try rootElement(arguments: arguments)
    let settling = settleBeforeObservation(app: app, root: appRoot, arguments: arguments)
    let includeElements = arguments["includeElements"]?.boolValue ?? false
    let includeTree = arguments["includeTree"]?.boolValue ?? false
    let includeDebug = arguments["includeDebug"]?.boolValue ?? false
    let maxDepth = try optionalIntegerArgument(arguments, "maxDepth", minimum: 0)
    let maxNodes = try optionalIntegerArgument(arguments, "maxNodes", minimum: 1)
    let maxTextCharacters = try optionalIntegerArgument(arguments, "maxTextCharacters", minimum: 1)
    let includeMacChrome = arguments["accessibilityScope"]?.stringValue == "menu_bar"
    let scopedRoot = try scopedAppStateRoot(appRoot: appRoot, arguments: arguments, maxDepth: maxDepth, maxNodes: maxNodes)
    let root = scopedRoot.element
    var remaining = maxNodes
    var visitedCount = 0
    var elements: [JSONValue] = []
    var stateRows: [AccessibilityStateRow] = []
    var observedElementIDs: Set<Int> = []
    let tree = indexedSnapshotElement(
      root,
      path: scopedRoot.path,
      depth: 0,
      parentElementIndex: nil,
      siblingIndex: 0,
      parentRole: nil,
      includeMacChrome: includeMacChrome,
      maxDepth: maxDepth,
      remaining: &remaining,
      visitedCount: &visitedCount,
      elements: &elements,
      stateRows: &stateRows,
      observedElementIDs: &observedElementIDs
    )
    latestObservedElementIDsByPID[app.processIdentifier] = observedElementIDs
    let focusedElement = elements.first { element in
      element.objectValue?["focused"]?.boolValue == true
    } ?? .null
    let focusedElementText = focusedElement.objectValue.map { "Focused element: \(elementLine($0))" }
    let header = appStateHeader(app: app, root: appRoot)
    var footer: [String] = []
    if settling?.objectValue?["timedOut"]?.boolValue == true {
      footer.append("Observation wait timed out; requested readiness was not confirmed. Do not assume the previous action completed.")
    }
    if isTraversalTruncated(remaining) {
      footer.append("Tree truncated. Re-run with a higher maxNodes value if needed.")
    }
    if let focusedElementText {
      footer.append(focusedElementText)
    }
    let depthKey = maxDepth.map { String($0) } ?? "unbounded"
    let nodeKey = maxNodes.map { String($0) } ?? "unbounded"
    let historyKeyParts: [String] = [
      String(app.processIdentifier),
      arguments["accessibilityScope"]?.stringValue ?? "application",
      String(stableElementIndex(for: appRoot)),
      scopedRoot.requestedIndex.map(String.init) ?? "root",
      depthKey,
      nodeKey
    ]
    let historyKey = historyKeyParts.joined(separator: ":")
    let stateRender = stateHistory.render(
      key: historyKey,
      header: header,
      rows: stateRows,
      footer: footer,
      disableDiff: arguments["disableDiff"]?.boolValue == true,
      maxTextCharacters: maxTextCharacters
    )
    var text = truncatedText(stateRender.text, maxCharacters: maxTextCharacters)
    let diffWasTruncated = text.truncated && stateRender.kind == "diff"
    if diffWasTruncated {
      text = truncatedText(stateRender.fullText, maxCharacters: maxTextCharacters)
    }
    let metrics: [String: JSONValue] = [
      "exposedElementCount": .number(Double(elements.count)),
      "lineCount": .number(Double(stateRender.fullText.split(separator: "\n", omittingEmptySubsequences: false).count)),
      "textCharacters": .number(Double(text.value.count)),
      "textCharactersBeforeTruncation": .number(Double(stateRender.text.count)),
      "visitedNodeCount": .number(Double(visitedCount))
    ]

    var result: [String: JSONValue] = [
      "app": .object([
        "bundleIdentifier": .from(app.bundleIdentifier),
        "localizedName": .from(app.localizedName),
        "pid": .number(Double(app.processIdentifier))
      ]),
      "success": .bool(true),
      "stateKind": .string(diffWasTruncated ? "full" : stateRender.kind),
      "stateRevision": .number(Double(stateRender.revision)),
      "text": .string(text.value),
      "window": windowDescription(for: appRoot)
    ]
    if let settling { result["settling"] = settling }
    if let baseRevision = stateRender.baseRevision, !diffWasTruncated {
      result["baseRevision"] = .number(Double(baseRevision))
    }
    if !includeMacChrome {
      let window = try selectedWindow(arguments: arguments)
      result["window_id"] = .number(Double(window.id))
      result["window"] = windowTargets.description(window.element, id: window.id)
    }
    if arguments["includeContextSnapshot"]?.boolValue == true {
      result["contextSnapshot"] = .object(["text": .string(stateRender.fullText)])
    }
    if arguments["includeScreenshot"]?.boolValue != false && !includeMacChrome {
      do {
        result["screenshot"] = try screenshot(arguments: [
          "pid": .number(Double(app.processIdentifier)),
          "scope": .string("window"),
          "window_id": result["window_id"] ?? .null
        ])
      } catch let error as PilotRuntimeError {
        result["screenshot"] = .null
        result["screenshotError"] = .object([
          "code": .string(error.code),
          "message": .string(error.message)
        ])
      }
    }
    if includeDebug {
      result["focusedElement"] = focusedElement
      result["focusedElementText"] = .from(focusedElementText)
      result["stateFormat"] = .string("text is a compact line-numbered Accessibility list; use the leading number as element_index")
      result["stateMetrics"] = .object(metrics)
      result["textTruncated"] = .bool(text.truncated)
      result["treeTruncated"] = .bool(isTraversalTruncated(remaining))
      result["truncated"] = .bool(isTraversalTruncated(remaining) || text.truncated)
    }
    if let rootElementIndex = scopedRoot.requestedIndex {
      result["rootElementIndex"] = .string(String(rootElementIndex))
      result["rootElementPath"] = .string(scopedRoot.path)
    }

    if includeElements {
      result["elements"] = .array(elements)
    }

    if includeTree {
      result["root"] = tree
    }

    return .object(result)
  }

  private func click(arguments: [String: JSONValue]) throws -> JSONValue {
    let clickCount = try optionalIntegerArgument(arguments, "click_count", minimum: 1) ?? 1
    let mouseButton = try mouseButtonArgument(arguments)
    let physical = physicalClickRequested(arguments) || mouseButton != .left
    if physical { _ = try prepareKeyboardTarget(arguments: arguments, foreground: true) }

    if let element = try actionElement(arguments: arguments) {
      if physical {
        let point = try centerPoint(of: element)
        showComputerUseCursor(at: point)
        try postMouseClick(
          at: point,
          clickCount: clickCount,
          button: mouseButton,
          targetPID: try runningApplication(arguments: arguments).processIdentifier
        )
        return .object([
          "click_count": .number(Double(clickCount)),
          "method": .string("cg_mouse_click"),
          "success": .bool(true),
          "target": describeElement(element, path: "target")
        ])
      }
      if let point = try? centerPoint(of: element) {
        showComputerUseCursor(at: point)
      }
      let method = try activateElement(element, clickCount: clickCount)
      return .object([
        "click_count": .number(Double(clickCount)),
        "method": .string(method),
        "success": .bool(true),
        "target": describeElement(element, path: "target")
      ])
    }

    let point = try coordinatePoint(arguments: arguments)
    let window = try selectedWindow(arguments: arguments)
    guard windowTargets.bounds(window.element)?.contains(point) == true else {
      throw PilotRuntimeError(code: "window_mismatch", message: "Click coordinates are outside the selected window.")
    }
    // Show the intended Computer Use position even when the coordinate does
    // not resolve to an actionable Accessibility element. This keeps the
    // software cursor useful for previews and makes failed actions observable.
    showComputerUseCursor(at: point)
    let method: String
    if physical {
      try postMouseClick(
        at: point,
        clickCount: clickCount,
        button: mouseButton,
        targetPID: try runningApplication(arguments: arguments).processIdentifier
      )
      method = "cg_mouse_click"
    } else {
      let root = try rootElement(arguments: arguments)
      var hit: AXUIElement?
      guard AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &hit) == .success, let hit else {
        throw PilotRuntimeError(code: "element_not_found", message: "No element at the requested coordinates.")
      }
      try validateWindow(hit, arguments: arguments)
      method = try activateElement(hit, clickCount: clickCount)
    }

    return .object([
      "click_count": .number(Double(clickCount)),
      "method": .string("\(method)_at_coordinate"),
      "success": .bool(true),
      "x": .number(point.x),
      "y": .number(point.y)
    ])
  }

  private func dismiss(arguments: [String: JSONValue]) throws -> JSONValue {
    let root = try rootElement(arguments: arguments)
    let target = try actionElement(arguments: arguments) ?? root
    try performAction(target, action: kAXCancelAction)
    return .object([
      "action": .string("cancel"),
      "success": .bool(true),
      "target": describeElement(target, path: "target")
    ])
  }

  private func typeText(arguments: [String: JSONValue]) throws -> JSONValue {
    guard let text = arguments["text"]?.stringValue else {
      throw PilotRuntimeError(code: "invalid_request", message: "type_text requires text.")
    }
    let app = try prepareKeyboardTarget(arguments: arguments)
    let target = try actionElement(arguments: arguments)
    if let target {
      let role = stringAttribute(target, kAXRoleAttribute) ?? ""
      guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) else {
        throw PilotRuntimeError(code: "invalid_request", message: "Targeted type_text requires an editable text control.")
      }
      _ = AXUIElementSetAttributeValue(target, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      let root = preparedRootElement(processIdentifier: app.processIdentifier)
      if !editableHasFocus(target, app: root) {
        _ = AXUIElementPerformAction(target, kAXPressAction as CFString)
      }
      for _ in 0..<6 {
        if editableHasFocus(target, app: root) { break }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
      }
      guard editableHasFocus(target, app: root) else {
        throw PilotRuntimeError(code: "element_focus_failed", message: "The requested editable control did not receive focus; no text was sent.")
      }
    } else if arguments["replace"]?.boolValue == true {
      throw PilotRuntimeError(code: "invalid_request", message: "replace requires element_index or selector.")
    }
    if arguments["replace"]?.boolValue == true {
      postKeyboardChord(try KeyboardChord.parse("Super_L+a"), targetPID: app.processIdentifier)
    }
    try postKeyboardText(text, targetPID: app.processIdentifier, arguments: arguments, expectedElement: target)
    if arguments["submit"]?.boolValue == true {
      if let target, !editableHasFocus(target, app: preparedRootElement(processIdentifier: app.processIdentifier)) {
        throw PilotRuntimeError(code: "element_focus_failed", message: "Text was sent but the control lost focus; Return was not sent.")
      }
      postKeyboardChord(try KeyboardChord.parse("Return"), targetPID: app.processIdentifier)
    }
    return .object([
      "charactersTyped": .number(Double(text.count)),
      "success": .bool(true)
    ])
  }

  private func pressKey(arguments: [String: JSONValue]) throws -> JSONValue {
    guard let key = arguments["key"]?.stringValue, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
      throw PilotRuntimeError(code: "invalid_request", message: "press_key requires key.")
    }
    let app = try prepareKeyboardTarget(arguments: arguments)
    let chord = try KeyboardChord.parse(key)
    guard keyboardTargetIsRunning(app.processIdentifier) else {
      throw PilotRuntimeError(code: "action_unavailable", message: "The requested app is no longer running.")
    }
    postKeyboardChord(chord, targetPID: app.processIdentifier)
    return .object(["key": .string(key), "success": .bool(true)])
  }

  private func drag(arguments: [String: JSONValue]) throws -> JSONValue {
    let from = try coordinatePoint(arguments: arguments, xName: "from_x", yName: "from_y")
    let to = try coordinatePoint(arguments: arguments, xName: "to_x", yName: "to_y")
    let app = try prepareKeyboardTarget(arguments: arguments, foreground: true)
    let window = try selectedWindow(arguments: arguments)
    guard let bounds = windowTargets.bounds(window.element), bounds.contains(from), bounds.contains(to) else {
      throw PilotRuntimeError(code: "window_mismatch", message: "Drag coordinates must stay within the selected window.")
    }
    guard app.isActive else {
      throw PilotRuntimeError(code: "action_unavailable", message: "Unable to drag because the requested app did not become active.")
    }
    showComputerUseCursor(at: from)
    try postMouseDrag(from: from, to: to, targetPID: app.processIdentifier)
    showComputerUseCursor(at: to)
    return .object([
      "from_x": .number(from.x), "from_y": .number(from.y),
      "to_x": .number(to.x), "to_y": .number(to.y),
      "success": .bool(true)
    ])
  }

  private func performSecondaryAction(arguments: [String: JSONValue]) throws -> JSONValue {
    guard let requested = arguments["action"]?.stringValue, !requested.isEmpty else {
      throw PilotRuntimeError(code: "invalid_request", message: "perform_secondary_action requires action.")
    }
    let element = try elementByRequiredIndexOrPath(arguments: arguments)
    let supported = actionNames(element)
    guard let action = supported.first(where: { $0 == requested || actionLabel($0) == requested.lowercased() }) else {
      throw PilotRuntimeError(
        code: "action_unavailable",
        message: "The element does not advertise accessibility action \(requested)."
      )
    }
    try performAction(element, action: action)
    return .object([
      "action": .string(action),
      "success": .bool(true),
      "target": describeElement(element, path: "target")
    ])
  }

  private func paste(arguments: [String: JSONValue]) throws -> JSONValue {
    guard let text = arguments["text"]?.stringValue else {
      throw PilotRuntimeError(code: "invalid_request", message: "paste requires text.")
    }
    let format = arguments["format"]?.stringValue ?? "text"
    guard ["text", "md", "html"].contains(format) else {
      throw PilotRuntimeError(code: "invalid_request", message: "paste format must be text, md, or html.")
    }
    let app = try prepareKeyboardTarget(arguments: arguments)
    guard keyboardTargetIsRunning(app.processIdentifier) else {
      throw PilotRuntimeError(code: "action_unavailable", message: "The requested app is no longer running.")
    }

    let pasteboard = NSPasteboard.general
    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
    pasteboard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    if format == "html" {
      item.setString(text, forType: .html)
    } else if format == "md" {
      item.setString(text, forType: NSPasteboard.PasteboardType("net.daringfireball.markdown"))
    }
    pasteboard.writeObjects([item])
    let ownedChangeCount = pasteboard.changeCount
    postKeyboardChord(try KeyboardChord.parse("Super_L+v"), targetPID: app.processIdentifier)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    let restored = pasteboard.changeCount == ownedChangeCount
    if restored {
      snapshot.restore(to: pasteboard)
    }
    return .object([
      "charactersPasted": .number(Double(text.count)),
      "clipboardRestored": .bool(restored),
      "format": .string(format),
      "success": .bool(true)
    ])
  }

  private func selectText(arguments: [String: JSONValue]) throws -> JSONValue {
    guard let needle = arguments["text"]?.stringValue, !needle.isEmpty else {
      throw PilotRuntimeError(code: "invalid_request", message: "select_text requires non-empty text.")
    }
    let selectionType = arguments["selection_type"]?.stringValue ?? "text"
    guard ["text", "cursor_before", "cursor_after"].contains(selectionType) else {
      throw PilotRuntimeError(code: "invalid_request", message: "selection_type must be text, cursor_before, or cursor_after.")
    }
    let element = try elementByRequiredIndexOrPath(arguments: arguments)
    guard let value = stringAttribute(element, kAXValueAttribute) else {
      throw PilotRuntimeError(code: "action_unavailable", message: "The target element has no textual AXValue.")
    }
    let range = try TextSelectionMatcher.uniqueRange(
      in: value,
      text: needle,
      prefix: arguments["prefix"]?.stringValue,
      suffix: arguments["suffix"]?.stringValue
    )
    var selectedRange = CFRange(location: range.location, length: range.length)
    if selectionType == "cursor_before" {
      selectedRange.length = 0
    } else if selectionType == "cursor_after" {
      selectedRange.location += selectedRange.length
      selectedRange.length = 0
    }
    guard let axRange = AXValueCreate(.cfRange, &selectedRange) else {
      throw PilotRuntimeError(code: "action_unavailable", message: "Unable to encode the selected text range.")
    }
    try setAttribute(element, kAXSelectedTextRangeAttribute, value: axRange)
    return .object([
      "location": .number(Double(selectedRange.location)),
      "length": .number(Double(selectedRange.length)),
      "selection_type": .string(selectionType),
      "success": .bool(true)
    ])
  }

  private func setValue(arguments: [String: JSONValue]) throws -> JSONValue {
    guard let value = arguments["value"]?.stringValue ?? arguments["text"]?.stringValue else {
      throw PilotRuntimeError(code: "invalid_request", message: "set_value requires value.")
    }
    let element = try elementByRequiredIndexOrPath(arguments: arguments)
    try setAttribute(element, kAXValueAttribute, value: value as CFTypeRef)
    return .object([
      "success": .bool(true),
      "target": describeElement(element, path: "target")
    ])
  }

  private func scroll(arguments: [String: JSONValue]) throws -> JSONValue {
    let direction = arguments["direction"]?.stringValue ?? "down"
    guard ["up", "down", "left", "right"].contains(direction) else {
      throw PilotRuntimeError(code: "invalid_request", message: "direction must be up, down, left, or right.")
    }
    let pages = try optionalIntegerArgument(arguments, "pages", minimum: 1) ?? 1

    if let element = try elementByOptionalIndex(arguments: arguments) {
      if let point = try? centerPoint(of: element) {
        showComputerUseCursor(at: point)
      }
      let action: String
      switch direction {
      case "up":
        action = "AXScrollUp"
      case "left":
        action = "AXScrollLeft"
      case "right":
        action = "AXScrollRight"
      default:
        action = "AXScrollDown"
      }
      for _ in 0..<pages {
        try performAction(element, action: action)
      }
      return .object([
        "direction": .string(direction),
        "pages": .number(Double(pages)),
        "success": .bool(true),
        "target": describeElement(element, path: "target")
      ])
    }

    _ = try prepareKeyboardTarget(arguments: arguments, foreground: true)
    let window = try selectedWindow(arguments: arguments)
    let original = CGEvent(source: nil)?.location ?? .zero
    defer { CGWarpMouseCursorPosition(original) }
    CGWarpMouseCursorPosition(try centerPoint(of: window.element))
    postScroll(direction: direction, pages: pages)
    return .object([
      "direction": .string(direction),
      "pages": .number(Double(pages)),
      "success": .bool(true)
    ])
  }

  private func rootElement(arguments: [String: JSONValue]) throws -> AXUIElement {
    let app = try runningApplication(arguments: arguments)
    let appRoot = preparedRootElement(processIdentifier: app.processIdentifier)

    switch arguments["accessibilityScope"]?.stringValue ?? "application" {
    case "application":
      return try selectedWindow(arguments: arguments).element
    case "menu_bar":
      guard let menuBar = try? copyElementAttribute(appRoot, kAXMenuBarAttribute as String) else {
        throw PilotRuntimeError(code: "element_not_found", message: "The target application has no accessible menu bar.")
      }
      return menuBar
    default:
      throw PilotRuntimeError(code: "invalid_request", message: "accessibilityScope must be application or menu_bar.")
    }
  }

  private func preparedRootElement(processIdentifier: pid_t) -> AXUIElement {
    _ = targetAccessibilitySupport.prepare(processIdentifier: processIdentifier)
    return AXUIElementCreateApplication(processIdentifier)
  }

  private func scopedAppStateRoot(
    appRoot: AXUIElement,
    arguments: [String: JSONValue],
    maxDepth: Int?,
    maxNodes: Int?
  ) throws -> (element: AXUIElement, index: Int, path: String, requestedIndex: Int?) {
    guard let rootElementIndex = try optionalElementIndexArgument(arguments, "rootElementIndex") else {
      return (appRoot, stableElementIndex(for: appRoot), "root", nil)
    }
    let element = try stableElement(at: rootElementIndex, arguments: arguments)
    try validateWindow(element, arguments: arguments)
    return (element, rootElementIndex, "element[\(rootElementIndex)]", rootElementIndex)
  }

  private func runningApplication(arguments: [String: JSONValue]) throws -> NSRunningApplication {
    if let pid = try processIdentifierArgument(arguments) {
      guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
        throw PilotRuntimeError(
          code: "app_not_found",
          message: "No running application has pid \(pid). Refresh app state and use its current pid."
        )
      }
      return app
    }

    if let bundleIdentifier = arguments["bundleIdentifier"]?.stringValue {
      if let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
      }) {
        return app
      }
      return try launchInstalledApplication(matching: bundleIdentifier)
    }

    if let appPath = arguments["path"]?.stringValue {
      let targetPath = URL(fileURLWithPath: appPath).standardizedFileURL.path
      if let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleURL?.standardizedFileURL.path == targetPath && !$0.isTerminated
      }) {
        return app
      }
      _ = try launchApp(arguments: ["path": .string(targetPath), "activate": .bool(true)])
      guard let app = runningApplication(bundleIdentifier: nil, path: targetPath) else {
        throw PilotRuntimeError(code: "app_not_found", message: "Launched app at \(appPath) did not become available.")
      }
      return app
    }

    if let appName = arguments["app"]?.stringValue {
      if let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.localizedName == appName || $0.bundleIdentifier == appName
      }) {
        return app
      }
      return try launchInstalledApplication(matching: appName)
    }

    return try frontmostApplication()
  }

  private func launchInstalledApplication(matching identifier: String) throws -> NSRunningApplication {
    let matches = installedApplications(bundleIdentifier: nil).filter {
      $0.localizedName == identifier || $0.bundleIdentifier == identifier
    }
    guard matches.count == 1, let match = matches.first else {
      throw PilotRuntimeError(
        code: matches.isEmpty ? "app_not_found" : "ambiguous_target",
        message: matches.isEmpty
          ? "Could not find installed app \(identifier)."
          : "Multiple installed apps match \(identifier); use a bundle identifier."
      )
    }
    _ = try launchApp(arguments: ["path": .string(match.path), "activate": .bool(true)])
    guard let app = runningApplication(bundleIdentifier: match.bundleIdentifier, path: match.path) else {
      throw PilotRuntimeError(code: "app_not_found", message: "Launched app \(identifier) did not become available.")
    }
    return app
  }

  private func settleBeforeObservation(app: NSRunningApplication, root: AXUIElement, arguments: [String: JSONValue]) -> JSONValue? {
    let actionAt = pendingSettleAtByPID.removeValue(forKey: app.processIdentifier)
    let expected = arguments["waitForText"]?.stringValue
    guard actionAt != nil || expected != nil else { return nil }
    let start = Date()
    let timeout = Double(arguments["timeoutMs"]?.intValue ?? 5000) / 1000
    let deadline = start.addingTimeInterval(timeout)
    var settler = ObservationSettler()
    var ready = false
    repeat {
      var remaining = 2000
      var parts: [String] = []
      var busy = false
      sampleReadiness(root, depth: 0, remaining: &remaining, parts: &parts, busy: &busy, deadline: deadline)
      if Date() >= deadline { break }
      ready = settler.ready(signature: parts.joined(separator: "\n"), busy: busy,
        elapsed: Date().timeIntervalSince(start), expected: expected)
      if ready { break }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    } while Date().timeIntervalSince(start) < timeout
    return .object(["timedOut": .bool(!ready), "condition": .string(expected == nil ? "stable" : "text"),
      "elapsedMs": .number(Date().timeIntervalSince(start) * 1000)])
  }

  private func sampleReadiness(_ element: AXUIElement, depth: Int, remaining: inout Int, parts: inout [String], busy: inout Bool, deadline: Date) {
    guard remaining > 0, depth < 24, Date() < deadline else { return }
    remaining -= 1
    let role = stringAttribute(element, kAXRoleAttribute)
    if let role { parts.append(role) }
    for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
      var value: CFTypeRef?
      if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value = value as? String {
        parts.append(String(value.prefix(500)))
      }
    }
    var value: CFTypeRef?
    _ = AXUIElementCopyAttributeValue(element, kAXElementBusyAttribute as CFString, &value)
    // WebKit exposes document loading separately from AXElementBusy.
    let isWeb = role == "AXWebArea"
    let loaded = isWeb ? windowTargets.attribute(element, "AXLoaded") as? Bool : nil
    let progress = isWeb ? windowTargets.attribute(element, "AXLoadingProgress") as? Double : nil
    if ObservationSettler.isLoading(role: role, busy: value as? Bool == true, loaded: loaded, progress: progress) { busy = true }
    var children: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success {
      for child in (children as? [AXUIElement] ?? []).prefix(remaining) {
        sampleReadiness(child, depth: depth + 1, remaining: &remaining, parts: &parts, busy: &busy, deadline: deadline)
      }
    }
  }

  private func processIdentifierArgument(_ arguments: [String: JSONValue]) throws -> pid_t? {
    guard let rawPID = arguments["pid"] else {
      return nil
    }
    guard let value = rawPID.intValue, let pid = pid_t(exactly: value), pid > 0 else {
      throw PilotRuntimeError(
        code: "invalid_request",
        message: "pid must be a positive process identifier."
      )
    }
    return pid
  }

  private func runningApplication(bundleIdentifier: String?, path: String?) -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { app in
      if let bundleIdentifier, app.bundleIdentifier == bundleIdentifier {
        return true
      }
      if let path, app.bundleURL?.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path {
        return true
      }
      return false
    }
  }

  private func runningApplicationDescription(_ app: NSRunningApplication) -> JSONValue {
    .object([
      "active": .bool(app.isActive),
      "bundleIdentifier": .from(app.bundleIdentifier),
      "localizedName": .from(app.localizedName),
      "path": .from(app.bundleURL?.path),
      "pid": .number(Double(app.processIdentifier)),
      "terminated": .bool(app.isTerminated)
    ])
  }

  private func installedApplications(bundleIdentifier: String?) -> [InstalledApplication] {
    var appsByPath: [String: InstalledApplication] = [:]

    if let bundleIdentifier,
       let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
       let app = installedApplication(at: url) {
      appsByPath[app.path] = app
    }

    let fileManager = FileManager.default
    for directory in applicationSearchDirectories() where fileManager.fileExists(atPath: directory.path) {
      guard let enumerator = fileManager.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      ) else {
        continue
      }

      for case let url as URL in enumerator {
        guard url.pathExtension == "app" else {
          continue
        }
        enumerator.skipDescendants()
        guard let app = installedApplication(at: url) else {
          continue
        }
        if let bundleIdentifier, app.bundleIdentifier != bundleIdentifier {
          continue
        }
        appsByPath[app.path] = app
      }
    }

    return Array(appsByPath.values)
  }

  private func applicationSearchDirectories() -> [URL] {
    [
      URL(fileURLWithPath: "/Applications"),
      URL(fileURLWithPath: "/System/Applications"),
      URL(fileURLWithPath: "/System/Applications/Utilities"),
      URL(fileURLWithPath: ("~/Applications" as NSString).expandingTildeInPath)
    ]
  }

  private func installedApplication(at url: URL) -> InstalledApplication? {
    let standardizedURL = url.standardizedFileURL
    let bundle = Bundle(url: standardizedURL)
    let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
    let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
    let fileName = standardizedURL.deletingPathExtension().lastPathComponent
    let localizedName = displayName ?? bundleName ?? fileName

    return InstalledApplication(
      bundleIdentifier: bundle?.bundleIdentifier,
      localizedName: localizedName,
      path: standardizedURL.path
    )
  }

  private func installedApplicationDescription(_ app: InstalledApplication) -> JSONValue {
    .object([
      "bundleIdentifier": .from(app.bundleIdentifier),
      "localizedName": .string(app.localizedName),
      "path": .string(app.path)
    ])
  }

  private func activateAppIfRequested(arguments: [String: JSONValue]) throws {
    guard arguments["app"] != nil ||
      arguments["bundleIdentifier"] != nil ||
      arguments["path"] != nil ||
      arguments["pid"] != nil else {
      return
    }
    let app = try runningApplication(arguments: arguments)
    _ = targetAccessibilitySupport.prepare(processIdentifier: app.processIdentifier)
    _ = activate(app)
    waitForActivation(app)
  }

  private func waitForActivation(_ app: NSRunningApplication) {
    for _ in 0..<10 {
      if app.isActive {
        return
      }
      usleep(50_000)
    }
  }

  @discardableResult
  private func activate(_ app: NSRunningApplication) -> Bool {
    app.unhide()
    let appElement = preparedRootElement(processIdentifier: app.processIdentifier)
    _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    if let window = try? copyElementAttribute(appElement, kAXFocusedWindowAttribute) {
      _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
      _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
      _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    let requested = app.activate(options: [.activateAllWindows])
    waitForActivation(app)
    return requested || app.isActive
  }

  private func frontmostApplication() throws -> NSRunningApplication {
    guard let app = NSWorkspace.shared.frontmostApplication else {
      throw PilotRuntimeError(code: "app_not_found", message: "Could not determine the frontmost macOS app.")
    }
    return app
  }

  private func resolveTarget(root: AXUIElement, arguments: [String: JSONValue]) throws -> AXUIElement {
    if let element = try elementByOptionalIndex(arguments: arguments, root: root) {
      return element
    }

    guard let selector = arguments["selector"]?.objectValue else {
      if let path = arguments["path"]?.stringValue {
        return try elementAtPath(root: root, path: path)
      }
      return root
    }

    if let path = selector["path"]?.stringValue {
      return try elementAtPath(root: root, path: path)
    }

    let occurrence = max(1, selector["occurrence"]?.intValue ?? 1)
    var matches: [AXUIElement] = []
    let maxDepth = try optionalIntegerArgument(arguments, "maxDepth", minimum: 0)
    collectMatches(root, selector: selector, depth: 0, maxDepth: maxDepth, matches: &matches)

    guard !matches.isEmpty else {
      throw PilotRuntimeError(code: "element_not_found", message: "No accessibility element matched selector.")
    }

    guard matches.count >= occurrence else {
      throw PilotRuntimeError(
        code: "element_not_found",
        message: "Selector matched \(matches.count) element(s), fewer than requested occurrence \(occurrence)."
      )
    }

    if matches.count > 1 && selector["occurrence"] == nil {
      throw PilotRuntimeError(
        code: "ambiguous_target",
        message: "Selector matched \(matches.count) elements; provide occurrence."
      )
    }

    return matches[occurrence - 1]
  }

  private func elementByOptionalIndex(arguments: [String: JSONValue], root explicitRoot: AXUIElement? = nil) throws -> AXUIElement? {
    guard let index = try optionalElementIndexArgument(arguments, "element_index", alternateName: "elementIndex") else {
      return nil
    }
    return try stableElement(at: index, arguments: arguments)
  }

  private func actionElement(arguments: [String: JSONValue]) throws -> AXUIElement? {
    if let element = try elementByOptionalIndex(arguments: arguments) {
      return element
    }
    guard arguments["selector"]?.objectValue != nil else {
      return nil
    }
    return try resolveTarget(root: rootElement(arguments: arguments), arguments: arguments)
  }

  private func elementByRequiredIndexOrPath(arguments: [String: JSONValue]) throws -> AXUIElement {
    let root = try rootElement(arguments: arguments)
    if let element = try elementByOptionalIndex(arguments: arguments, root: root) {
      return element
    }
    if let path = arguments["path"]?.stringValue {
      return try elementAtPath(root: root, path: path)
    }
    throw PilotRuntimeError(code: "invalid_request", message: "Action requires element_index or path.")
  }

  private func elementAtPath(root: AXUIElement, path: String) throws -> AXUIElement {
    let indices = try parseSnapshotPath(path)
    var current = root

    for index in indices {
      let children = try copyElementArrayAttribute(current, kAXChildrenAttribute)
      guard index >= 0 && index < children.count else {
        throw PilotRuntimeError(
          code: "element_not_found",
          message: "Snapshot path \(path) is no longer valid; child index \(index) is outside \(children.count) children."
        )
      }
      current = children[index]
    }

    return current
  }

  private func parseSnapshotPath(_ path: String) throws -> [Int] {
    if path == "root" {
      return []
    }

    let pattern = #"^root(?:\.children\[(\d+)\])*$"#
    guard path.range(of: pattern, options: .regularExpression) != nil else {
      throw PilotRuntimeError(
        code: "invalid_request",
        message: "Snapshot path must look like root.children[0].children[1]."
      )
    }

    let segmentPattern = #"\.children\[(\d+)\]"#
    let regex = try! NSRegularExpression(pattern: segmentPattern)
    let range = NSRange(path.startIndex..<path.endIndex, in: path)
    return regex.matches(in: path, range: range).compactMap { match in
      guard let matchRange = Range(match.range(at: 1), in: path) else {
        return nil
      }
      return Int(path[matchRange])
    }
  }

  private func collectMatches(
    _ element: AXUIElement,
    selector: [String: JSONValue],
    depth: Int,
    maxDepth: Int?,
    matches: inout [AXUIElement]
  ) {
    if elementMatches(element, selector: selector) {
      matches.append(element)
    }

    guard shouldTraverseChildren(depth: depth, maxDepth: maxDepth),
          let children = try? copyElementArrayAttribute(element, kAXChildrenAttribute) else {
      return
    }

    for child in children {
      collectMatches(child, selector: selector, depth: depth + 1, maxDepth: maxDepth, matches: &matches)
    }
  }

  private func elementMatches(_ element: AXUIElement, selector: [String: JSONValue]) -> Bool {
    for (key, expected) in selector {
      if key == "occurrence" || key == "path" {
        continue
      }

      let actual: String?
      switch key {
      case "role":
        actual = stringAttribute(element, kAXRoleAttribute)
      case "subrole":
        actual = stringAttribute(element, kAXSubroleAttribute)
      case "title":
        actual = stringAttribute(element, kAXTitleAttribute)
      case "value":
        actual = stringAttribute(element, kAXValueAttribute)
      case "description":
        actual = stringAttribute(element, kAXDescriptionAttribute)
      default:
        continue
      }

      guard let expectedString = expected.stringValue, actual == expectedString else {
        return false
      }
    }

    return true
  }

  private func indexedSnapshotElement(
    _ element: AXUIElement,
    path: String,
    depth: Int,
    parentElementIndex: Int?,
    siblingIndex: Int,
    parentRole: String?,
    includeMacChrome: Bool,
    maxDepth: Int?,
    remaining: inout Int?,
    visitedCount: inout Int,
    elements: inout [JSONValue],
    stateRows: inout [AccessibilityStateRow],
    observedElementIDs: inout Set<Int>,
    ancestorLabels: Set<String> = []
  ) -> JSONValue {
    guard consumeNode(&remaining) else {
      return .object(["truncated": .bool(true)])
    }

    let index = stableElementIndex(for: element)
    visitedCount += 1
    guard observedElementIDs.insert(index).inserted else {
      return .object([
        "index": .string(String(index)),
        "path": .string(path),
        "reference": .bool(true)
      ])
    }
    var node = describeElement(element, path: path).objectValue ?? [:]
    node["index"] = .string(String(index))
    node["actions"] = .array(actionNames(element).map { .string($0) })
    enrichCompactLineNode(&node, from: element)
    let role = humanRole(node["role"]?.stringValue)
    let rendered = shouldRenderStateLine(node, depth: depth, parentRole: parentRole, includeMacChrome: includeMacChrome, ancestorLabels: ancestorLabels)
    if rendered {
      let line = "\(stateLineIndent(depth))\(elementLine(node))"
      stateRows.append(AccessibilityStateRow(
        elementIndex: index,
        line: line,
        parentElementIndex: parentElementIndex,
        siblingIndex: siblingIndex
      ))
    }
    let elementSummary = compactElementSummary(node)
    if shouldExposeElement(elementSummary) {
      elements.append(.object(elementSummary))
    }

    guard shouldTraverseChildren(depth: depth, maxDepth: maxDepth),
          let children = try? copyElementArrayAttribute(element, kAXChildrenAttribute),
          !children.isEmpty else {
      return .object(node)
    }

    let childLabels = rendered ? ancestorLabels.union(stateTextLabels(node)) : ancestorLabels
    let childNodes = boundedChildNodes(children, remaining: &remaining) {
      child, childIndex, remaining in
      indexedSnapshotElement(
        child,
        path: "\(path).children[\(childIndex)]",
        depth: depth + 1,
        parentElementIndex: index,
        siblingIndex: childIndex,
        parentRole: role,
        includeMacChrome: includeMacChrome,
        maxDepth: maxDepth,
        remaining: &remaining,
        visitedCount: &visitedCount,
        elements: &elements,
        stateRows: &stateRows,
        observedElementIDs: &observedElementIDs,
        ancestorLabels: childLabels
      )
    }
    node["children"] = .array(childNodes)
    return .object(node)
  }

  private func appStateHeader(app: NSRunningApplication, root: AXUIElement) -> [String] {
    var lines = [
      "Computer Use Accessibility list",
      "Use the leading stable number as element_index for actions.",
      "App=\(app.bundleURL?.path ?? app.bundleIdentifier ?? app.localizedName ?? String(app.processIdentifier)) (bundleID \(app.bundleIdentifier ?? "unknown"), pid \(app.processIdentifier))"
    ]
    if let window = windowDescription(for: root).objectValue {
      lines.append("Window: \(elementLine(window))")
    }
    return lines
  }

  private func optionalIntegerArgument(_ arguments: [String: JSONValue], _ name: String, minimum: Int) throws -> Int? {
    guard let rawValue = arguments[name] else {
      return nil
    }
    guard let value = rawValue.intValue else {
      throw PilotRuntimeError(code: "invalid_request", message: "\(name) must be an integer.")
    }
    guard value >= minimum else {
      throw PilotRuntimeError(code: "invalid_request", message: "\(name) must be greater than or equal to \(minimum).")
    }
    return value
  }

  private func optionalElementIndexArgument(
    _ arguments: [String: JSONValue],
    _ name: String,
    alternateName: String? = nil
  ) throws -> Int? {
    let rawValue = arguments[name] ?? alternateName.flatMap { arguments[$0] }
    guard let rawValue else {
      return nil
    }

    let index: Int?
    if let stringValue = rawValue.stringValue {
      index = Int(stringValue)
    } else {
      index = rawValue.intValue
    }

    guard let index, index >= 0 else {
      throw PilotRuntimeError(code: "invalid_request", message: "\(name) must be a non-negative integer string.")
    }
    return index
  }

  private func shouldTraverseChildren(depth: Int, maxDepth: Int?) -> Bool {
    guard let maxDepth else {
      return true
    }
    return depth < maxDepth
  }

  private func consumeNode(_ remaining: inout Int?) -> Bool {
    guard let current = remaining else {
      return true
    }
    guard current > 0 else {
      return false
    }
    remaining = current - 1
    return true
  }

  private func isTraversalTruncated(_ remaining: Int?) -> Bool {
    guard let remaining else {
      return false
    }
    return remaining <= 0
  }

  private func truncatedText(_ value: String, maxCharacters: Int?) -> (value: String, truncated: Bool) {
    guard let maxCharacters else {
      return (value, false)
    }
    guard value.count > maxCharacters else {
      return (value, false)
    }
    return ("\(String(value.prefix(maxCharacters)))\n...[truncated]", true)
  }

  private func stateLineIndent(_ depth: Int) -> String {
    String(repeating: "  ", count: depth)
  }

  func shouldRenderStateLine(
    _ element: [String: JSONValue],
    depth: Int,
    parentRole: String?,
    includeMacChrome: Bool,
    ancestorLabels: Set<String> = []
  ) -> Bool {
    let role = humanRole(element["role"]?.stringValue)
    // Short static text includes prices, stock status, and sizes. Never drop it
    // merely because it could have been a label for a subsequent control.
    if roleIsReadableText(role) && !hasAnyTextAttribute(element) { return false }
    if roleIsReadableText(role), element["focused"]?.boolValue != true,
       element["settable"]?.boolValue != true,
       !stateTextLabels(element).isEmpty,
       stateTextLabels(element).isSubset(of: ancestorLabels) { return false }
    if role == "group", !hasAnyTextAttribute(element),
       element["focused"]?.boolValue != true, element["settable"]?.boolValue != true,
       !shouldRenderGroupLine(element),
       (element["actions"] == nil || element["actions"] == .array([])) { return false }
    if parentRole == "cell", roleIsReadableText(role) {
      return false
    }
    if role == "cell" && parentRole == "row" {
      return false
    }
    if shouldHideCompactStateLine(element, role: role, includeMacChrome: includeMacChrome) {
      return false
    }
    if depth <= 2 {
      return true
    }
    if element["focused"]?.boolValue == true || element["settable"]?.boolValue == true {
      return true
    }
    if roleIsActionable(role) || roleIsReadableText(role) || roleIsListItem(role) || role == "heading" || role == "tab" {
      return true
    }
    if role == "web area" && hasAnyTextAttribute(element) {
      return true
    }
    if role == "group", shouldRenderGroupLine(element) {
      return true
    }
    if let actions = element["actions"],
       case .array(let values) = actions,
       values.compactMap(\.stringValue).contains(where: { shouldShowAction($0, role: role) }) {
      return true
    }
    return false
  }

  private func shouldHideCompactStateLine(
    _ element: [String: JSONValue],
    role: String,
    includeMacChrome: Bool
  ) -> Bool {
    if shouldHideMacChromeRole(role, includeMacChrome: includeMacChrome) {
      return true
    }
    if roleIsListItem(role) && !hasAnyTextAttribute(element) && element["selected"]?.boolValue != true {
      return true
    }
    if role == "button", let subrole = element["subrole"]?.stringValue, shouldHideSubrole(subrole, role: role) {
      return true
    }
    return false
  }

  private func stateTextLabels(_ element: [String: JSONValue]) -> Set<String> {
    let role = humanRole(element["role"]?.stringValue)
    let keys = roleIsReadableText(role) ? ["title", "description", "value"] : ["title", "description"]
    return Set(keys.compactMap { element[$0]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
  }

  private func enrichCompactLineNode(_ node: inout [String: JSONValue], from element: AXUIElement) {
    let role = humanRole(node["role"]?.stringValue)
    guard roleIsListItem(role), !hasAnyTextAttribute(node) else {
      return
    }
    let labels = descendantTextLabels(element, limit: 3)
    guard !labels.isEmpty else {
      return
    }
    node["title"] = .string(labels.joined(separator: ", "))
  }

  private func descendantTextLabels(_ element: AXUIElement, limit: Int) -> [String] {
    var labels: [String] = []
    collectDescendantTextLabels(element, labels: &labels, limit: limit, depth: 0)
    return labels
  }

  private func collectDescendantTextLabels(_ element: AXUIElement, labels: inout [String], limit: Int, depth: Int) {
    guard labels.count < limit, depth < 4 else {
      return
    }
    if depth > 0, let label = preferredTextLabel(element), !labels.contains(label) {
      labels.append(label)
      if labels.count >= limit {
        return
      }
    }
    guard let children = try? copyElementArrayAttribute(element, kAXChildrenAttribute) else {
      return
    }
    for child in children {
      collectDescendantTextLabels(child, labels: &labels, limit: limit, depth: depth + 1)
      if labels.count >= limit {
        return
      }
    }
  }

  private func preferredTextLabel(_ element: AXUIElement) -> String? {
    for attribute in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
      if let value = stringAttribute(element, attribute), !value.isEmpty {
        let normalized = compactAttributeValue(value)
        if !normalized.isEmpty {
          return normalized
        }
      }
    }
    return nil
  }

  private func preferredTextLabel(_ element: [String: JSONValue]) -> String? {
    for key in ["title", "value", "description"] {
      if let value = element[key]?.stringValue, !value.isEmpty {
        let normalized = compactAttributeValue(value)
        if !normalized.isEmpty {
          return normalized
        }
      }
    }
    return nil
  }

  private func hasAnyTextAttribute(_ element: [String: JSONValue]) -> Bool {
    for key in ["title", "value", "description"] {
      if let value = element[key]?.stringValue, !value.isEmpty {
        return true
      }
    }
    return false
  }

  private func shouldRenderGroupLine(_ element: [String: JSONValue]) -> Bool {
    guard let subrole = element["subrole"]?.stringValue else {
      return false
    }
    return subrole.hasPrefix("AXLandmark")
  }

  func elementLine(_ element: [String: JSONValue]) -> String {
    var segments: [String] = []
    let index = element["index"]?.stringValue
    if let index {
      segments.append(index)
    }

    let role = humanRole(element["role"]?.stringValue)
    let settable = element["settable"]?.boolValue == true
    let displayRole = compactRoleName(role, element: element)
    var roleSegment = displayRole
    var modifiers: [String] = []
    if element["enabled"]?.boolValue == false {
      modifiers.append("disabled")
    }
    if element["focused"]?.boolValue == true {
      modifiers.append("focused")
    }
    if element["selected"]?.boolValue == true {
      modifiers.append("selected")
    }
    if settable {
      modifiers.append("settable")
    }
    if !modifiers.isEmpty {
      roleSegment += " [\(modifiers.joined(separator: ","))]"
    }
    segments.append(roleSegment)

    appendTextAttribute("title", from: element, to: &segments)
    if element["description"]?.stringValue != element["title"]?.stringValue {
      appendTextAttribute("description", label: "desc", from: element, to: &segments)
    }
    appendCompactValue(from: element, role: displayRole, to: &segments)
    appendCompactSubrole(from: element, role: role, to: &segments)

    if let actions = element["actions"],
       case .array(let values) = actions {
      let names = values
        .compactMap(\.stringValue)
        .filter { shouldShowAction($0, role: role) }
      if !names.isEmpty {
        segments.append("actions=\(names.map(actionLabel).joined(separator: ","))")
      }
    }

    return segments.joined(separator: " ")
  }

  private func appendTextAttribute(
    _ key: String,
    label: String? = nil,
    from element: [String: JSONValue],
    to segments: inout [String]
  ) {
    guard let value = element[key]?.stringValue, !value.isEmpty else {
      return
    }
    let compactValue = compactAttributeValue(value)
    if let label {
      segments.append("\(label)=\(quoted(compactValue))")
    } else {
      segments.append(quoted(compactValue))
    }
  }

  private func appendCompactSubrole(from element: [String: JSONValue], role: String, to segments: inout [String]) {
    guard let subrole = element["subrole"]?.stringValue, !subrole.isEmpty else {
      return
    }
    if shouldHideSubrole(subrole, role: role) {
      return
    }
    segments.append("subrole=\(quoted(stripAXPrefix(subrole)))")
  }

  private func appendCompactValue(from element: [String: JSONValue], role: String, to segments: inout [String]) {
    guard let value = element["value"]?.stringValue, !value.isEmpty else {
      return
    }
    let compactValue = compactAttributeValue(value)
    if let booleanValue = booleanValueLabel(compactValue), roleUsesBooleanValue(role) {
      segments.append("value=\(booleanValue)")
    } else {
      segments.append("value=\(quoted(compactValue))")
    }
  }

  private func roleUsesBooleanValue(_ role: String) -> Bool {
    role == "switch" ||
      role == "check box" ||
      role == "radio button"
  }

  private func booleanValueLabel(_ value: String) -> String? {
    switch value.lowercased() {
    case "0", "false", "off":
      return "off"
    case "1", "true", "on":
      return "on"
    default:
      return nil
    }
  }

  private func compactRoleName(_ role: String, element: [String: JSONValue]) -> String {
    if role == "check box", element["subrole"]?.stringValue == "AXSwitch" {
      return "switch"
    }
    return role
  }

  private func humanRole(_ role: String?) -> String {
    let stripped = stripAXPrefix(role ?? "element")
    let spaced = stripped.replacingOccurrences(
      of: #"([a-z])([A-Z])"#,
      with: "$1 $2",
      options: .regularExpression
    )
    return spaced.lowercased()
  }

  private func stripAXPrefix(_ value: String) -> String {
    value.hasPrefix("AX") ? String(value.dropFirst(2)) : value
  }

  private func shouldShowAction(_ action: String, role: String) -> Bool {
    switch action {
    case "AXShowMenu", "AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI":
      return false
    case "AXPress":
      return !roleImpliesPress(role)
    default:
      return !action.hasPrefix("Name:")
    }
  }

  private func roleImpliesPress(_ role: String) -> Bool {
    roleIsActionable(role) ||
      role == "tab"
  }

  private func shouldHideSubrole(_ subrole: String, role: String) -> Bool {
    switch subrole {
    case "AXCloseButton", "AXDecrementArrow", "AXDecrementPage", "AXIncrementArrow", "AXIncrementPage",
         "AXMinimizeButton", "AXOutlineRow", "AXSearchField", "AXSegment", "AXSortButton", "AXStandardWindow",
         "AXSwitch", "AXTableRow", "AXZoomButton":
      return true
    default:
      break
    }
    if role == "group" && subrole == "AXHostingView" {
      return true
    }
    return false
  }

  func shouldHideMacChromeRole(_ role: String, includeMacChrome: Bool) -> Bool {
    !includeMacChrome && (
      role == "menu bar" ||
      role == "menu" ||
      role == "menu bar item" ||
      role == "menu item" ||
      role == "scroll bar" ||
      role == "splitter" ||
      role == "toolbar" ||
      role == "value indicator"
    )
  }

  private func roleIsReadableText(_ role: String) -> Bool {
    role == "static text" ||
      role == "text" ||
      role == "text field" ||
      role == "text area"
  }

  private func roleIsListItem(_ role: String) -> Bool {
    role == "row" ||
      role == "cell" ||
      role == "outline row"
  }

  private func roleIsActionable(_ role: String) -> Bool {
    role.contains("button") ||
      role == "link" ||
      role == "menu item" ||
      role == "checkbox" ||
      role == "check box" ||
      role == "radio button"
  }

  private func actionLabel(_ value: String) -> String {
    stripAXPrefix(value)
      .replacingOccurrences(of: "Name:", with: "")
      .replacingOccurrences(of: " ", with: "_")
      .lowercased()
  }

  private func compactAttributeValue(_ value: String) -> String {
    let normalized = value
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.count > compactAttributeCharacterLimit else {
      return normalized
    }
    return "\(String(normalized.prefix(compactAttributeCharacterLimit)))..."
  }

  private func quoted(_ value: String) -> String {
    let escaped = value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
    return "\"\(escaped)\""
  }

  private func compactElementSummary(_ node: [String: JSONValue]) -> [String: JSONValue] {
    var summary: [String: JSONValue] = [:]
    for key in ["index", "path", "role", "subrole", "title", "value", "description", "enabled", "focused", "selected", "settable", "frame", "actions"] {
      if let value = node[key] {
        summary[key] = value
      }
    }
    return summary
  }

  private func shouldExposeElement(_ element: [String: JSONValue]) -> Bool {
    if element["focused"]?.boolValue == true {
      return true
    }
    if let actions = element["actions"],
       case .array(let values) = actions,
       !values.isEmpty {
      return true
    }
    for key in ["title", "value", "description"] {
      if let value = element[key]?.stringValue, !value.isEmpty {
        return true
      }
    }
    return false
  }

  private func describeElement(_ element: AXUIElement, path: String) -> JSONValue {
    var values: [String: JSONValue] = ["path": .string(path)]

    copyStringAttribute(element, kAXRoleAttribute, into: &values, as: "role")
    copyStringAttribute(element, kAXSubroleAttribute, into: &values, as: "subrole")
    copyStringAttribute(element, kAXTitleAttribute, into: &values, as: "title")
    copyStringAttribute(element, kAXValueAttribute, into: &values, as: "value")
    copyStringAttribute(element, kAXDescriptionAttribute, into: &values, as: "description")
    copyBoolAttribute(element, kAXEnabledAttribute, into: &values, as: "enabled")
    copyBoolAttribute(element, kAXFocusedAttribute, into: &values, as: "focused")
    copyBoolAttribute(element, kAXSelectedAttribute, into: &values, as: "selected")
    copySettableAttribute(element, kAXValueAttribute, into: &values, as: "settable")
    copyFrame(element, into: &values)

    return .object(values)
  }

  private func windowDescription(for appElement: AXUIElement) -> JSONValue {
    if (windowTargets.attribute(appElement, kAXRoleAttribute) as? String) == kAXWindowRole {
      return describeElement(appElement, path: "window")
    }
    guard let window = try? copyElementAttribute(appElement, kAXFocusedWindowAttribute) else {
      return .null
    }
    return describeElement(window, path: "window")
  }

  private func actionNames(_ element: AXUIElement) -> [String] {
    var actionNames: CFArray?
    guard AXUIElementCopyActionNames(element, &actionNames) == .success,
          let values = actionNames as? [String] else {
      return []
    }
    return values
  }

  private func elementSupportsAction(_ element: AXUIElement, action: String) -> Bool {
    actionNames(element).contains(action)
  }

  private func coordinatePoint(arguments: [String: JSONValue]) throws -> CGPoint {
    try coordinatePoint(arguments: arguments, xName: "x", yName: "y")
  }

  private func coordinatePoint(arguments: [String: JSONValue], xName: String, yName: String) throws -> CGPoint {
    guard let x = arguments[xName]?.numberValue,
          let y = arguments[yName]?.numberValue else {
      throw PilotRuntimeError(
        code: "invalid_request",
        message: "Coordinate actions require numeric \(xName) and \(yName)."
      )
    }
    return CGPoint(x: x, y: y)
  }

  private func centerPoint(of element: AXUIElement) throws -> CGPoint {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    let positionError = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue)
    let sizeError = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
    guard positionError == .success,
          sizeError == .success,
          let positionValue,
          let sizeValue else {
      throw PilotRuntimeError(
        code: "action_unavailable",
        message: "Unable to click element by coordinates because its frame is unavailable: position \(positionError), size \(sizeError)."
      )
    }

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
          size.width > 0,
          size.height > 0 else {
      throw PilotRuntimeError(code: "action_unavailable", message: "Unable to click element by coordinates because its frame is invalid.")
    }

    return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
  }

  private func activateElement(at point: CGPoint, clickCount: Int) throws -> String {
    var element: AXUIElement?
    let error = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element)
    guard error == .success, let element else {
      throw PilotRuntimeError(
        code: "action_unavailable",
        message: "Unable to resolve an accessible element at the requested coordinate without moving the user's cursor."
      )
    }

    return try activateElement(element, clickCount: clickCount)
  }

  private func activateElement(_ element: AXUIElement, clickCount: Int) throws -> String {
    var current = element
    for _ in 0..<12 {
      if elementSupportsAction(current, action: kAXPressAction) {
        for _ in 0..<clickCount {
          try performAction(current, action: kAXPressAction)
        }
        return "ax_press"
      }
      if isAttributeSettable(current, kAXSelectedAttribute as String) {
        try setAttribute(current, kAXSelectedAttribute as String, value: kCFBooleanTrue)
        return "ax_select"
      }
      guard let parent = try? copyElementAttribute(current, kAXParentAttribute as String) else {
        break
      }
      current = parent
    }

    throw PilotRuntimeError(
      code: "action_unavailable",
      message: "The element has no accessible press or selection action. Refusing to synthesize a physical click that would move the user's cursor."
    )
  }

  private func showComputerUseCursor(at point: CGPoint) {
    let duration = cursorOverlay.showClick(at: point)
    guard duration > 0 else {
      return
    }

    // The stdio request is synchronous, so keep its response pending while
    // allowing the main run loop to render the Core Animation frames. This
    // prevents a following command from interrupting the movement before the
    // cursor reaches the point where the accessibility action occurs.
    RunLoop.main.run(until: Date(timeIntervalSinceNow: duration))
  }

  private func postMouseClick(
    at point: CGPoint,
    clickCount: Int,
    button: CGMouseButton = .left,
    targetPID: pid_t
  ) throws {
    let input = targetBoundMouseInput()
    do {
      try input.click(at: point, clickCount: clickCount, button: button, targetPID: targetPID)
    } catch TargetBoundMouseInputError.targetLostFocus {
      throw PilotRuntimeError(
        code: "action_unavailable",
        message: "Unable to click because the requested app no longer owns focus."
      )
    }
  }

  private func postMouseDrag(from: CGPoint, to: CGPoint, targetPID: pid_t) throws {
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
      throw PilotRuntimeError(code: "action_unavailable", message: "Unable to drag because the requested app no longer owns focus.")
    }
    let original = CGEvent(source: nil)?.location ?? .zero
    defer { CGWarpMouseCursorPosition(original) }
    let source = CGEventSource(stateID: .hidSystemState)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)?
      .post(tap: .cghidEventTap)
    for step in 1...20 {
      guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: from, mouseButton: .left)?
          .post(tap: .cghidEventTap)
        throw PilotRuntimeError(code: "action_unavailable", message: "The requested app lost focus during the drag.")
      }
      let progress = CGFloat(step) / 20
      let point = CGPoint(x: from.x + ((to.x - from.x) * progress), y: from.y + ((to.y - from.y) * progress))
      CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
      usleep(10_000)
    }
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)?
      .post(tap: .cghidEventTap)
  }

  private func targetBoundMouseInput() -> TargetBoundMouseInput {
    TargetBoundMouseInput(
      isTargetFocused: { targetPID in
        NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
      },
      currentPointerLocation: {
        CGEvent(source: nil)?.location ?? .zero
      },
      postClicks: postMouseEvents,
      restorePointerLocation: { point in
        CGWarpMouseCursorPosition(point)
      }
    )
  }

  private func postMouseEvents(at point: CGPoint, clickCount: Int, button: CGMouseButton) {
    let source = CGEventSource(stateID: .hidSystemState)
    let downType: CGEventType
    let upType: CGEventType
    switch button {
    case .right:
      downType = .rightMouseDown
      upType = .rightMouseUp
    case .center:
      downType = .otherMouseDown
      upType = .otherMouseUp
    default:
      downType = .leftMouseDown
      upType = .leftMouseUp
    }
    for clickIndex in 1...clickCount {
      let down = CGEvent(
        mouseEventSource: source,
        mouseType: downType,
        mouseCursorPosition: point,
        mouseButton: button
      )
      let up = CGEvent(
        mouseEventSource: source,
        mouseType: upType,
        mouseCursorPosition: point,
        mouseButton: button
      )
      down?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      up?.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
      down?.post(tap: .cghidEventTap)
      usleep(20_000)
      up?.post(tap: .cghidEventTap)
      if clickIndex < clickCount {
        usleep(80_000)
      }
    }
  }

  private func mouseButtonArgument(_ arguments: [String: JSONValue]) throws -> CGMouseButton {
    switch arguments["mouse_button"]?.stringValue?.lowercased() ?? "left" {
    case "left", "l": return .left
    case "right", "r": return .right
    case "middle", "m", "center": return .center
    default:
      throw PilotRuntimeError(code: "invalid_request", message: "mouse_button must be left, right, or middle.")
    }
  }

  private func postKeyboardText(_ text: String, targetPID: pid_t, arguments: [String: JSONValue], expectedElement: AXUIElement? = nil) throws {
    let source = CGEventSource(stateID: .hidSystemState)
    let window = try selectedWindow(arguments: arguments)
    let appRoot = preparedRootElement(processIdentifier: targetPID)
    let input = TargetBoundKeyboardInput(
      isTargetFocused: { [self] pid in
        guard keyboardTargetIsRunning(pid), windowTargets.isKeyboardTarget(window.element, app: appRoot) else { return false }
        guard let expectedElement else { return true }
        return editableHasFocus(expectedElement, app: appRoot)
      },
      pauseBetweenCharacters: { usleep(5_000) },
      postCharacter: { [self] character in
        switch character {
        case "\n", "\r":
          postKey(source: source, keyCode: 36, targetPID: targetPID)
        case "\t":
          postKey(source: source, keyCode: 48, targetPID: targetPID)
        default:
          postUnicodeCharacter(source: source, character, targetPID: targetPID)
        }
      }
    )
    do {
      try input.post(text, targetPID: targetPID)
    } catch TargetBoundKeyboardInputError.targetLostFocus {
      throw PilotRuntimeError(
        code: "action_unavailable",
        message: "Typing stopped because the selected window lost keyboard focus or the app exited."
      )
    }
  }

  private func editableHasFocus(_ element: AXUIElement, app: AXUIElement) -> Bool {
    var focused: CFTypeRef?
    AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
    return focused.map { CFEqual($0, element) } ?? false
  }

  private func prepareKeyboardTarget(arguments: [String: JSONValue], foreground: Bool = false) throws -> NSRunningApplication {
    let app = try runningApplication(arguments: arguments)
    let window = try selectedWindow(arguments: arguments)
    if foreground {
      _ = activate(app)
      guard app.isActive else {
        throw PilotRuntimeError(code: "window_focus_failed", message: "The selected app could not be brought to the foreground.")
      }
    }
    let root = preparedRootElement(processIdentifier: app.processIdentifier)
    try windowTargets.focus(window.element, app: root, allowRaise: foreground)
    return app
  }

  private func postKeyboardChord(_ chord: KeyboardChord, targetPID: pid_t) {
    let source = CGEventSource(stateID: .hidSystemState)
    if let text = chord.text, let character = text.first {
      postUnicodeCharacter(source: source, character, targetPID: targetPID)
      return
    }
    guard let keyCode = chord.keyCode else { return }
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = chord.flags
    down?.postToPid(targetPID)
    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = chord.flags
    up?.postToPid(targetPID)
  }

  private func stableElementIndex(for element: AXUIElement) -> Int {
    let hash = CFHash(element)
    if let existing = elementBuckets[hash]?.first(where: { CFEqual($0.element, element) }) {
      return existing.index
    }
    let index = nextElementIndex
    nextElementIndex += 1
    elementBuckets[hash, default: []].append((index, element))
    return index
  }

  private func stableElement(at index: Int, arguments: [String: JSONValue]) throws -> AXUIElement {
    guard let element = elementBuckets.values.lazy.flatMap({ $0 }).first(where: { $0.index == index })?.element else {
      throw PilotRuntimeError(code: "stale_element", message: "Element \(index) is not part of this Computer Use session. Call get_app_state again.")
    }
    let app = try runningApplication(arguments: arguments)
    guard element.pid == app.processIdentifier else {
      throw PilotRuntimeError(code: "stale_element", message: "Element \(index) belongs to a different app. Call get_app_state again.")
    }
    guard latestObservedElementIDsByPID[app.processIdentifier]?.contains(index) == true else {
      throw PilotRuntimeError(code: "stale_element", message: "Element \(index) is not present in the latest app state. Call get_app_state again.")
    }
    var role: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else {
      throw PilotRuntimeError(code: "stale_element", message: "Element \(index) is no longer available. Call get_app_state again.")
    }
    try validateWindow(element, arguments: arguments)
    return element
  }

  private func keyboardTargetIsRunning(_ targetPID: pid_t) -> Bool {
    guard let app = NSRunningApplication(processIdentifier: targetPID) else { return false }
    return !app.isTerminated
  }

  private func postUnicodeCharacter(source: CGEventSource?, _ character: Character, targetPID: pid_t) {
    var units = Array(String(character).utf16)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
    down?.postToPid(targetPID)

    let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
    up?.postToPid(targetPID)
  }

  private func postKey(source: CGEventSource?, keyCode: CGKeyCode, targetPID: pid_t) {
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.postToPid(targetPID)

    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.postToPid(targetPID)
  }

  private func postScroll(direction: String, pages: Int) {
    let source = CGEventSource(stateID: .hidSystemState)
    let amount = Int32(10 * pages)
    let vertical: Int32
    let horizontal: Int32
    switch direction {
    case "up":
      vertical = amount
      horizontal = 0
    case "left":
      vertical = 0
      horizontal = amount
    case "right":
      vertical = 0
      horizontal = -amount
    default:
      vertical = -amount
      horizontal = 0
    }
    let event = CGEvent(
      scrollWheelEvent2Source: source,
      units: .line,
      wheelCount: 2,
      wheel1: vertical,
      wheel2: horizontal,
      wheel3: 0
    )
    event?.post(tap: CGEventTapLocation.cghidEventTap)
  }

  private func copyFrame(_ element: AXUIElement, into values: inout [String: JSONValue]) {
    var positionValue: CFTypeRef?
    var sizeValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
          AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
          let positionValue,
          let sizeValue else {
      return
    }

    var point = CGPoint.zero
    var size = CGSize.zero
    guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
          AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
      return
    }

    values["frame"] = .object([
      "height": .number(size.height),
      "width": .number(size.width),
      "x": .number(point.x),
      "y": .number(point.y)
    ])
  }

  private func copyStringAttribute(_ element: AXUIElement, _ attribute: String, into values: inout [String: JSONValue], as key: String) {
    guard let value = stringAttribute(element, attribute), !value.isEmpty else {
      return
    }
    values[key] = .string(value)
  }

  private func copyBoolAttribute(_ element: AXUIElement, _ attribute: String, into values: inout [String: JSONValue], as key: String) {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let boolValue = value as? Bool else {
      return
    }
    values[key] = .bool(boolValue)
  }

  private func copySettableAttribute(_ element: AXUIElement, _ attribute: String, into values: inout [String: JSONValue], as key: String) {
    var settable = DarwinBoolean(false)
    guard AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success else {
      return
    }
    values[key] = .bool(settable.boolValue)
  }

  private func isAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
  }

  private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
          let value else {
      return nil
    }
    return String(describing: value)
  }

  private func copyElementAttribute(_ element: AXUIElement, _ attribute: String) throws -> AXUIElement {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success, let value else {
      throw PilotRuntimeError(code: "attribute_unavailable", message: "Unable to read \(attribute): \(error).")
    }
    return (value as! AXUIElement)
  }

  private func copyElementArrayAttribute(_ element: AXUIElement, _ attribute: String) throws -> [AXUIElement] {
    var value: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
    guard error == .success else {
      throw PilotRuntimeError(code: "attribute_unavailable", message: "Unable to read \(attribute): \(error).")
    }
    return (value as? [AXUIElement]) ?? []
  }

  private func performAction(_ element: AXUIElement, action: String) throws {
    let error = AXUIElementPerformAction(element, action as CFString)
    guard error == .success else {
      throw PilotRuntimeError(code: "action_unavailable", message: "Unable to perform \(action): \(error).")
    }
  }

  private func setAttribute(_ element: AXUIElement, _ attribute: String, value: CFTypeRef) throws {
    let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
    guard error == .success else {
      throw PilotRuntimeError(code: "action_unavailable", message: "Unable to set \(attribute): \(error).")
    }
  }
}

struct PilotRuntimeError: Error {
  let code: String
  let message: String
}

private extension AXUIElement {
  var pid: pid_t {
    var pid = pid_t()
    AXUIElementGetPid(self, &pid)
    return pid
  }
}
