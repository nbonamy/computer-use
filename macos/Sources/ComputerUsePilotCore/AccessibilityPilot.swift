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
  private let cursorOverlay: ComputerUseCursorOverlay
  private let initialCursorPresenter: () -> Void
  private var didPresentInitialCursor = false

  public init(cursorOverlay: ComputerUseCursorOverlay = ComputerUseCursorOverlay()) {
    self.cursorOverlay = cursorOverlay
    self.initialCursorPresenter = { cursorOverlay.showAtMainScreenCenter() }
  }

  init(
    cursorOverlay: ComputerUseCursorOverlay = ComputerUseCursorOverlay(),
    initialCursorPresenter: @escaping () -> Void
  ) {
    self.cursorOverlay = cursorOverlay
    self.initialCursorPresenter = initialCursorPresenter
  }

  public func handle(_ request: PilotRequest) -> PilotResponse {
    presentInitialCursorIfNeeded()
    switch request.command {
    case "ping":
      return .success(id: request.id, result: .object(["success": .bool(true)]))
    case "status":
      return .success(id: request.id, result: status())
    case "request_accessibility":
      return .success(id: request.id, result: requestAccessibility(arguments: request.arguments))
    case "list_apps":
      return .success(id: request.id, result: listApps())
    case "find_apps":
      return runtimeGuard(id: request.id) { try findApps(arguments: request.arguments) }
    case "launch_app":
      return runtimeGuard(id: request.id) { try launchApp(arguments: request.arguments) }
    case "focus_app":
      return .success(id: request.id, result: focusApp(arguments: request.arguments))
    case "get_app_state":
      return accessibilityGuard(id: request.id) { try getAppState(arguments: request.arguments) }
    case "click":
      return accessibilityGuard(id: request.id) { try click(arguments: request.arguments) }
    case "type_text":
      return accessibilityGuard(id: request.id) { try typeText(arguments: request.arguments) }
    case "set_value":
      return accessibilityGuard(id: request.id) { try setValue(arguments: request.arguments) }
    case "scroll":
      return accessibilityGuard(id: request.id) { try scroll(arguments: request.arguments) }
    case "focused":
      return accessibilityGuard(id: request.id) { try focused() }
    case "snapshot":
      return accessibilityGuard(id: request.id) { try snapshot(arguments: request.arguments) }
    case "perform":
      return accessibilityGuard(id: request.id) { try perform(arguments: request.arguments) }
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

  private func status() -> JSONValue {
    .object([
      "accessibilityTrusted": .bool(AXIsProcessTrusted()),
      "platform": .string("macos"),
      "protocol": .string("computer-use-pilot.v1"),
      "success": .bool(true)
    ])
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
      let app = try runningApplication(arguments: arguments)
      let activated = app.activate(options: [.activateAllWindows])
      waitForActivation(app)
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

  private func focused() throws -> JSONValue {
    let app = try frontmostApplication()
    let focusedApp = AXUIElementCreateApplication(app.processIdentifier)
    let pid = app.processIdentifier
    let focusedWindow = try? copyElementAttribute(focusedApp, kAXFocusedWindowAttribute)

    var result: [String: JSONValue] = [
      "app": .object([
        "bundleIdentifier": .from(app.bundleIdentifier),
        "localizedName": .from(app.localizedName),
        "pid": .number(Double(pid))
      ]),
      "success": .bool(true)
    ]

    if let focusedWindow {
      result["window"] = describeElement(focusedWindow, path: "focused.window")
    }

    return .object(result)
  }

  private func snapshot(arguments: [String: JSONValue]) throws -> JSONValue {
    let root = try rootElement(arguments: arguments)
    let maxDepth = try optionalIntegerArgument(arguments, "maxDepth", minimum: 0)
    let maxNodes = try optionalIntegerArgument(arguments, "maxNodes", minimum: 1)
    var remaining = maxNodes
    let tree = snapshotElement(root, path: "root", depth: 0, maxDepth: maxDepth, remaining: &remaining)
    return .object([
      "root": tree,
      "success": .bool(true),
      "truncated": .bool(isTraversalTruncated(remaining))
    ])
  }

  private func getAppState(arguments: [String: JSONValue]) throws -> JSONValue {
    let appRoot = try rootElement(arguments: arguments)
    let app = try runningApplication(arguments: arguments)
    let includeElements = arguments["includeElements"]?.boolValue ?? false
    let includeTree = arguments["includeTree"]?.boolValue ?? false
    let includeDebug = arguments["includeDebug"]?.boolValue ?? false
    let maxDepth = try optionalIntegerArgument(arguments, "maxDepth", minimum: 0)
    let maxNodes = try optionalIntegerArgument(arguments, "maxNodes", minimum: 1)
    let maxTextCharacters = try optionalIntegerArgument(arguments, "maxTextCharacters", minimum: 1)
    let scopedRoot = try scopedAppStateRoot(appRoot: appRoot, arguments: arguments, maxDepth: maxDepth, maxNodes: maxNodes)
    let root = scopedRoot.element
    var remaining = maxNodes
    var nextIndex = scopedRoot.index
    var elements: [JSONValue] = []
    var treeLines: [String] = []
    var pendingSiblingLabel: String?
    let tree = indexedSnapshotElement(
      root,
      path: scopedRoot.path,
      depth: 0,
      parentRole: nil,
      pendingSiblingLabel: &pendingSiblingLabel,
      maxDepth: maxDepth,
      remaining: &remaining,
      nextIndex: &nextIndex,
      elements: &elements,
      treeLines: &treeLines
    )
    let focusedElement = elements.first { element in
      element.objectValue?["focused"]?.boolValue == true
    } ?? .null
    let focusedElementText = focusedElement.objectValue.map { "Focused element: \(elementLine($0))" }
    let stateText = appStateText(
      app: app,
      root: appRoot,
      treeLines: treeLines,
      focusedElementText: focusedElementText,
      truncated: isTraversalTruncated(remaining)
    )
    let text = truncatedText(stateText, maxCharacters: maxTextCharacters)
    let metrics: [String: JSONValue] = [
      "exposedElementCount": .number(Double(elements.count)),
      "lineCount": .number(Double(stateText.split(separator: "\n", omittingEmptySubsequences: false).count)),
      "textCharacters": .number(Double(text.value.count)),
      "textCharactersBeforeTruncation": .number(Double(stateText.count)),
      "visitedNodeCount": .number(Double(nextIndex - scopedRoot.index))
    ]

    var result: [String: JSONValue] = [
      "app": .object([
        "bundleIdentifier": .from(app.bundleIdentifier),
        "localizedName": .from(app.localizedName),
        "pid": .number(Double(app.processIdentifier))
      ]),
      "success": .bool(true),
      "text": .string(text.value),
      "window": windowDescription(for: appRoot)
    ]
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
    try activateAppIfRequested(arguments: arguments)

    let clickCount = max(1, arguments["click_count"]?.intValue ?? 1)

    if let element = try elementByOptionalIndex(arguments: arguments) {
      let point = try? centerPoint(of: element)
      if let point {
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
    // Show the intended Computer Use position even when the coordinate does
    // not resolve to an actionable Accessibility element. This keeps the
    // software cursor useful for previews and makes failed actions observable.
    showComputerUseCursor(at: point)
    let method = try activateElement(at: point, clickCount: clickCount)

    return .object([
      "click_count": .number(Double(clickCount)),
      "method": .string("\(method)_at_coordinate"),
      "success": .bool(true),
      "x": .number(point.x),
      "y": .number(point.y)
    ])
  }

  private func typeText(arguments: [String: JSONValue]) throws -> JSONValue {
    guard let text = arguments["text"]?.stringValue else {
      throw PilotRuntimeError(code: "invalid_request", message: "type_text requires text.")
    }

    try activateAppIfRequested(arguments: arguments)
    postKeyboardText(text)
    return .object([
      "charactersTyped": .number(Double(text.count)),
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
    let pages = max(1, arguments["pages"]?.intValue ?? 1)

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

    postScroll(direction: direction, pages: pages)
    return .object([
      "direction": .string(direction),
      "pages": .number(Double(pages)),
      "success": .bool(true)
    ])
  }

  private func perform(arguments: [String: JSONValue]) throws -> JSONValue {
    guard let action = arguments["action"]?.stringValue else {
      throw PilotRuntimeError(code: "invalid_request", message: "perform requires action.")
    }

    let root = try rootElement(arguments: arguments)
    let target = try resolveTarget(root: root, arguments: arguments)

    switch action {
    case "press":
      try performAction(target, action: kAXPressAction)
    case "focus":
      try setAttribute(target, kAXFocusedAttribute, value: kCFBooleanTrue)
    case "set_value":
      guard let text = arguments["text"]?.stringValue else {
        throw PilotRuntimeError(code: "invalid_request", message: "set_value requires text.")
      }
      try setAttribute(target, kAXValueAttribute, value: text as CFTypeRef)
    case "type_text":
      guard let text = arguments["text"]?.stringValue else {
        throw PilotRuntimeError(code: "invalid_request", message: "type_text requires text.")
      }
      try setAttribute(target, kAXFocusedAttribute, value: kCFBooleanTrue)
      try setAttribute(target, kAXValueAttribute, value: text as CFTypeRef)
    default:
      throw PilotRuntimeError(code: "unknown_action", message: "Unknown action \(action).")
    }

    return .object([
      "action": .string(action),
      "target": describeElement(target, path: "target"),
      "success": .bool(true)
    ])
  }

  private func rootElement(arguments: [String: JSONValue]) throws -> AXUIElement {
    if let pid = arguments["pid"]?.intValue {
      guard NSWorkspace.shared.runningApplications.contains(where: { $0.processIdentifier == pid_t(pid) && !$0.isTerminated }) else {
        throw PilotRuntimeError(code: "app_not_found", message: "No running application has pid \(pid). Refresh app state and use its current pid.")
      }
      return AXUIElementCreateApplication(pid_t(pid))
    }

    if let appName = arguments["app"]?.stringValue {
      let app = NSWorkspace.shared.runningApplications.first {
        $0.localizedName == appName || $0.bundleIdentifier == appName
      }
      guard let app else {
        throw PilotRuntimeError(code: "app_not_found", message: "Could not find running app \(appName).")
      }
      return AXUIElementCreateApplication(app.processIdentifier)
    }

    return AXUIElementCreateApplication(try frontmostApplication().processIdentifier)
  }

  private func scopedAppStateRoot(
    appRoot: AXUIElement,
    arguments: [String: JSONValue],
    maxDepth: Int?,
    maxNodes: Int?
  ) throws -> (element: AXUIElement, index: Int, path: String, requestedIndex: Int?) {
    guard let rootElementIndex = try optionalElementIndexArgument(arguments, "rootElementIndex") else {
      return (appRoot, 0, "root", nil)
    }

    let result = try elementAtIndexWithPath(
      root: appRoot,
      targetIndex: rootElementIndex,
      maxDepth: maxDepth,
      maxNodes: maxNodes
    )
    return (result.element, rootElementIndex, result.path, rootElementIndex)
  }

  private func runningApplication(arguments: [String: JSONValue]) throws -> NSRunningApplication {
    if let pid = arguments["pid"]?.intValue,
       let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
      return app
    }

    if let appName = arguments["app"]?.stringValue {
      let app = NSWorkspace.shared.runningApplications.first {
        $0.localizedName == appName || $0.bundleIdentifier == appName
      }
      guard let app else {
        throw PilotRuntimeError(code: "app_not_found", message: "Could not find running app \(appName).")
      }
      return app
    }

    return try frontmostApplication()
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
    guard arguments["app"] != nil || arguments["pid"] != nil else {
      return
    }
    let app = try runningApplication(arguments: arguments)
    app.activate(options: [.activateAllWindows])
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
    let root = try explicitRoot ?? rootElement(arguments: arguments)
    let maxDepth = try optionalIntegerArgument(arguments, "maxDepth", minimum: 0)
    let maxNodes = try optionalIntegerArgument(arguments, "maxNodes", minimum: 1)
    return try elementAtIndex(root: root, targetIndex: index, maxDepth: maxDepth, maxNodes: maxNodes)
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

  private func elementAtIndex(root: AXUIElement, targetIndex: Int, maxDepth: Int?, maxNodes: Int?) throws -> AXUIElement {
    try elementAtIndexWithPath(root: root, targetIndex: targetIndex, maxDepth: maxDepth, maxNodes: maxNodes).element
  }

  private func elementAtIndexWithPath(
    root: AXUIElement,
    targetIndex: Int,
    maxDepth: Int?,
    maxNodes: Int?
  ) throws -> (element: AXUIElement, path: String) {
    var currentIndex = 0
    var remaining = maxNodes
    if let result = findElementAtIndex(
      root,
      targetIndex: targetIndex,
      path: "root",
      depth: 0,
      maxDepth: maxDepth,
      remaining: &remaining,
      currentIndex: &currentIndex
    ) {
      return result
    }
    throw PilotRuntimeError(code: "element_not_found", message: "No element exists at element_index \(targetIndex). Call get_app_state again.")
  }

  private func findElementAtIndex(
    _ element: AXUIElement,
    targetIndex: Int,
    path: String,
    depth: Int,
    maxDepth: Int?,
    remaining: inout Int?,
    currentIndex: inout Int
  ) -> (element: AXUIElement, path: String)? {
    guard consumeNode(&remaining) else {
      return nil
    }

    if currentIndex == targetIndex {
      return (element, path)
    }
    currentIndex += 1

    guard shouldTraverseChildren(depth: depth, maxDepth: maxDepth),
          let children = try? copyElementArrayAttribute(element, kAXChildrenAttribute) else {
      return nil
    }
    for (childIndex, child) in children.enumerated() {
      if let match = findElementAtIndex(
        child,
        targetIndex: targetIndex,
        path: "\(path).children[\(childIndex)]",
        depth: depth + 1,
        maxDepth: maxDepth,
        remaining: &remaining,
        currentIndex: &currentIndex
      ) {
        return match
      }
    }
    return nil
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

  private func snapshotElement(
    _ element: AXUIElement,
    path: String,
    depth: Int,
    maxDepth: Int?,
    remaining: inout Int?
  ) -> JSONValue {
    guard consumeNode(&remaining) else {
      return .object(["truncated": .bool(true)])
    }

    var node = describeElement(element, path: path).objectValue ?? [:]
    guard shouldTraverseChildren(depth: depth, maxDepth: maxDepth),
          let children = try? copyElementArrayAttribute(element, kAXChildrenAttribute),
          !children.isEmpty else {
      return .object(node)
    }

    node["children"] = .array(children.enumerated().map { index, child in
      snapshotElement(child, path: "\(path).children[\(index)]", depth: depth + 1, maxDepth: maxDepth, remaining: &remaining)
    })
    return .object(node)
  }

  private func indexedSnapshotElement(
    _ element: AXUIElement,
    path: String,
    depth: Int,
    parentRole: String?,
    pendingSiblingLabel: inout String?,
    maxDepth: Int?,
    remaining: inout Int?,
    nextIndex: inout Int,
    elements: inout [JSONValue],
    treeLines: inout [String]
  ) -> JSONValue {
    guard consumeNode(&remaining) else {
      return .object(["truncated": .bool(true)])
    }

    let index = nextIndex
    nextIndex += 1
    var node = describeElement(element, path: path).objectValue ?? [:]
    node["index"] = .string(String(index))
    node["actions"] = .array(actionNames(element).map { .string($0) })
    enrichCompactLineNode(&node, from: element)
    let role = humanRole(node["role"]?.stringValue)
    if shouldCaptureSiblingLabel(node, role: role) {
      pendingSiblingLabel = preferredTextLabel(node)
      node["siblingLabelCaptured"] = .bool(true)
    } else {
      applyPendingSiblingLabel(&node, role: role, pendingSiblingLabel: &pendingSiblingLabel)
    }
    if shouldRenderStateLine(node, depth: depth, parentRole: parentRole) {
      treeLines.append("\(stateLineIndent(depth))\(elementLine(node))")
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

    var pendingSiblingLabel: String?
    var childNodes: [JSONValue] = []
    for (childIndex, child) in children.enumerated() {
      childNodes.append(
        indexedSnapshotElement(
          child,
          path: "\(path).children[\(childIndex)]",
          depth: depth + 1,
          parentRole: role,
          pendingSiblingLabel: &pendingSiblingLabel,
          maxDepth: maxDepth,
          remaining: &remaining,
          nextIndex: &nextIndex,
          elements: &elements,
          treeLines: &treeLines
        )
      )
    }
    node["children"] = .array(childNodes)
    return .object(node)
  }

  private func appStateText(
    app: NSRunningApplication,
    root: AXUIElement,
    treeLines: [String],
    focusedElementText: String?,
    truncated: Bool
  ) -> String {
    var lines = [
      "Computer Use Accessibility list",
      "Use the leading number on a line as element_index for click, set_value, or scroll.",
      "App=\(app.bundleURL?.path ?? app.bundleIdentifier ?? app.localizedName ?? String(app.processIdentifier)) (bundleID \(app.bundleIdentifier ?? "unknown"), pid \(app.processIdentifier))"
    ]
    if let window = windowDescription(for: root).objectValue {
      lines.append("Window: \(elementLine(window))")
    }
    lines.append(contentsOf: treeLines)
    if truncated {
      lines.append("Tree truncated. Re-run with a higher maxNodes value if needed.")
    }
    if let focusedElementText {
      lines.append(focusedElementText)
    }
    return lines.joined(separator: "\n")
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
    ""
  }

  private func shouldRenderStateLine(_ element: [String: JSONValue], depth: Int, parentRole: String?) -> Bool {
    let role = humanRole(element["role"]?.stringValue)
    if element["siblingLabelCaptured"]?.boolValue == true {
      return false
    }
    if parentRole == "cell", roleIsReadableText(role) {
      return false
    }
    if role == "cell" && parentRole == "row" {
      return false
    }
    if shouldHideCompactStateLine(element, role: role) {
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

  private func shouldHideCompactStateLine(_ element: [String: JSONValue], role: String) -> Bool {
    if roleIsMacChrome(role) {
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

  private func shouldCaptureSiblingLabel(_ node: [String: JSONValue], role: String) -> Bool {
    guard role == "static text" || role == "text" else {
      return false
    }
    guard let label = preferredTextLabel(node) else {
      return false
    }
    return label.count <= 80
  }

  private func applyPendingSiblingLabel(_ node: inout [String: JSONValue], role: String, pendingSiblingLabel: inout String?) {
    guard let label = pendingSiblingLabel else {
      return
    }
    defer { pendingSiblingLabel = nil }
    guard roleCanUseSiblingLabel(role), node["title"] == nil else {
      return
    }
    node["title"] = .string(label)
  }

  private func roleCanUseSiblingLabel(_ role: String) -> Bool {
    roleIsActionable(role) ||
      role == "check box" ||
      role == "pop up button" ||
      role == "combo box" ||
      role == "slider" ||
      role == "text field"
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

  private func elementLine(_ element: [String: JSONValue]) -> String {
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
    appendTextAttribute("description", label: "desc", from: element, to: &segments)
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

  private func roleIsMacChrome(_ role: String) -> Bool {
    role == "menu bar" ||
      role == "menu" ||
      role == "menu bar item" ||
      role == "menu item" ||
      role == "scroll bar" ||
      role == "splitter" ||
      role == "toolbar" ||
      role == "value indicator"
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
    guard let x = arguments["x"]?.numberValue,
          let y = arguments["y"]?.numberValue else {
      throw PilotRuntimeError(code: "invalid_request", message: "click requires element_index or x and y.")
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

  private func postKeyboardText(_ text: String) {
    let source = CGEventSource(stateID: .hidSystemState)
    for character in text {
      switch character {
      case "\n", "\r":
        postKey(source: source, keyCode: 36)
      case "\t":
        postKey(source: source, keyCode: 48)
      default:
        postUnicodeCharacter(source: source, character)
      }
      usleep(5_000)
    }
  }

  private func postUnicodeCharacter(source: CGEventSource?, _ character: Character) {
    var units = Array(String(character).utf16)
    let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
    down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
    down?.post(tap: .cghidEventTap)

    let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
    up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
    up?.post(tap: .cghidEventTap)
  }

  private func postKey(source: CGEventSource?, keyCode: CGKeyCode) {
    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.post(tap: .cghidEventTap)

    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.post(tap: .cghidEventTap)
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

private struct PilotRuntimeError: Error {
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
