import AppKit
import CoreGraphics
import XCTest
@testable import ComputerUsePilotCore

final class PilotProtocolTests: XCTestCase {
  @MainActor
  func testAmbiguousCommandsRejectMissingWindowBeforeAnySideEffects() {
    var cursorCount = 0
    let capturer = FakeScreenCapturer()
    let pilot = AccessibilityPilot(initialCursorPresenter: { cursorCount += 1 }, screenCapturer: capturer)
    let commands = ["get_app_state", "screenshot", "focus_app", "click", "dismiss",
      "type_text", "press_key", "drag", "perform_secondary_action", "paste",
      "select_text", "set_value", "scroll"]
    for command in commands {
      for scope in ["application", "menu_bar"] {
        if command == "get_app_state" && scope == "menu_bar" { continue }
        let result = pilot.handle(PilotRequest(id: command, command: command,
          arguments: ["accessibilityScope": .string(scope)]))
        XCTAssertFalse(result.ok, command)
        XCTAssertEqual(result.error?.code, "invalid_request", command)
        XCTAssertTrue(result.error?.message.contains("window_id is required") == true, command)
      }
    }
    XCTAssertEqual(cursorCount, 0)
    XCTAssertTrue(capturer.windowProcessIdentifiers.isEmpty)
  }

  @MainActor
  func testWindowIDMustBeAPositiveInteger() {
    let pilot = AccessibilityPilot(initialCursorPresenter: {})
    for value: JSONValue in [.null, .number(0), .number(-1), .number(1.5), .string("1"), .number(1e100)] {
      let result = pilot.handle(PilotRequest(id: "invalid-window", command: "press_key", arguments: ["window_id": value]))
      XCTAssertFalse(result.ok)
      XCTAssertEqual(result.error?.code, "invalid_request")
    }
  }

  @MainActor
  func testScreenshotUsesTheExplicitWindow() {
    let capturer = FakeScreenCapturer()
    let pid = try! XCTUnwrap(NSWorkspace.shared.frontmostApplication).processIdentifier
    let pilot = AccessibilityPilot(initialCursorPresenter: {}, screenCapturer: capturer, windowTargets: fakeWindowTargets(pid: pid))

    let response = pilot.handle(PilotRequest(
      id: "window-shot",
      command: "screenshot",
      arguments: ["pid": .number(Double(pid)), "window_id": .number(1)]
    ))

    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.result?.objectValue?["scope"]?.stringValue, "window")
    XCTAssertEqual(capturer.windowProcessIdentifiers, [pid])
    XCTAssertTrue(capturer.screenDisplayIdentifiers.isEmpty)
  }

  @MainActor
  func testScreenshotCapturesARequestedFullScreen() {
    let capturer = FakeScreenCapturer()
    let pilot = AccessibilityPilot(initialCursorPresenter: {}, screenCapturer: capturer)

    let response = pilot.handle(PilotRequest(
      id: "screen-shot",
      command: "screenshot",
      arguments: ["scope": .string("screen"), "displayId": .number(42)]
    ))

    XCTAssertTrue(response.ok)
    XCTAssertEqual(response.result?.objectValue?["scope"]?.stringValue, "screen")
    XCTAssertEqual(capturer.screenDisplayIdentifiers, [42])
    XCTAssertTrue(capturer.windowProcessIdentifiers.isEmpty)
  }

  @MainActor
  func testScreenshotResolvesBundleAndPathSelectorsWithoutFallingBack() throws {
    let app = try XCTUnwrap(NSWorkspace.shared.runningApplications.first(where: {
      $0.bundleIdentifier != nil && $0.bundleURL != nil && !$0.isTerminated
    }))
    let capturer = FakeScreenCapturer()
    let pilot = AccessibilityPilot(initialCursorPresenter: {}, screenCapturer: capturer, windowTargets: fakeWindowTargets(pid: app.processIdentifier))

    let byBundle = pilot.handle(PilotRequest(
      id: "bundle-shot",
      command: "screenshot",
      arguments: ["bundleIdentifier": .string(try XCTUnwrap(app.bundleIdentifier)), "window_id": .number(1)]
    ))
    let byPath = pilot.handle(PilotRequest(
      id: "path-shot",
      command: "screenshot",
      arguments: ["path": .string(try XCTUnwrap(app.bundleURL).path), "window_id": .number(1)]
    ))

    XCTAssertTrue(byBundle.ok)
    XCTAssertTrue(byPath.ok)
    XCTAssertEqual(capturer.windowProcessIdentifiers, [app.processIdentifier, app.processIdentifier])
  }

  @MainActor
  func testScreenshotRejectsUnknownScopesAndInvalidDisplayIdentifiers() {
    let capturer = FakeScreenCapturer()
    let pilot = AccessibilityPilot(initialCursorPresenter: {}, screenCapturer: capturer)

    for arguments: [String: JSONValue] in [
      ["scope": .string("desktop")],
      ["scope": .string("screen"), "displayId": .number(0)]
    ] {
      let response = pilot.handle(PilotRequest(id: "invalid-shot", command: "screenshot", arguments: arguments))
      XCTAssertFalse(response.ok)
      XCTAssertEqual(response.error?.code, "invalid_request")
    }
  }

  @MainActor
  func testScreenCapturePermissionUsesTheCaptureProvider() {
    let capturer = FakeScreenCapturer()
    capturer.isTrusted = false
    capturer.requestResult = true
    let pilot = AccessibilityPilot(initialCursorPresenter: {}, screenCapturer: capturer)

    let status = pilot.handle(PilotRequest(id: "status", command: "status"))
    let requested = pilot.handle(PilotRequest(id: "request", command: "request_screen_capture"))

    XCTAssertEqual(status.result?.objectValue?["screenCaptureTrusted"]?.boolValue, false)
    XCTAssertEqual(requested.result?.objectValue?["screenCaptureTrusted"]?.boolValue, true)
    XCTAssertEqual(capturer.requestCount, 1)
  }

  func testCursorAnimationDurationScalesAndStaysWithinHumanMovementBounds() {
    XCTAssertEqual(computerUseCursorAnimationDuration(for: 10), 0.16)
    XCTAssertEqual(computerUseCursorAnimationDuration(for: 700), 0.5)
    XCTAssertEqual(computerUseCursorAnimationDuration(for: 2_000), 0.55)
  }

  @MainActor
  func testMenuBarScopeExposesNormallyHiddenMacChromeRoles() {
    let pilot = AccessibilityPilot(initialCursorPresenter: {})

    XCTAssertTrue(pilot.shouldHideMacChromeRole("menu bar item", includeMacChrome: false))
    XCTAssertFalse(pilot.shouldHideMacChromeRole("menu bar item", includeMacChrome: true))
    XCTAssertFalse(pilot.shouldHideMacChromeRole("button", includeMacChrome: false))
  }

  @MainActor
  func testPilotPresentsTheInitialCursorOnlyOnTheFirstRequest() {
    var presentationCount = 0
    let pilot = AccessibilityPilot(initialCursorPresenter: { presentationCount += 1 })

    _ = pilot.handle(PilotRequest(id: "first", command: "ping"))
    _ = pilot.handle(PilotRequest(id: "second", command: "ping"))

    XCTAssertEqual(presentationCount, 1)
  }

  @MainActor
  func testScreenshotDoesNotPresentTheComputerUseCursor() {
    var presentationCount = 0
    let capturer = FakeScreenCapturer()
    let pilot = AccessibilityPilot(
      initialCursorPresenter: { presentationCount += 1 },
      screenCapturer: capturer
    )

    let response = pilot.handle(PilotRequest(
      id: "screen-shot",
      command: "screenshot",
      arguments: ["scope": .string("screen")]
    ))

    XCTAssertTrue(response.ok)
    XCTAssertEqual(presentationCount, 0)
  }

  @MainActor
  func testScreenshotTemporarilyHidesAndRestoresAnExistingCursor() {
    var events: [String] = []
    let cursor = FakeCursorOverlay(events: { events.append($0) })
    let capturer = FakeScreenCapturer(onCapture: { events.append("capture") })
    let pilot = AccessibilityPilot(
      cursorOverlay: cursor,
      initialCursorPresenter: { cursor.showAtMainScreenCenter() },
      screenCapturer: capturer
    )

    _ = pilot.handle(PilotRequest(id: "show", command: "ping"))
    _ = pilot.handle(PilotRequest(
      id: "screen-shot",
      command: "screenshot",
      arguments: ["scope": .string("screen")]
    ))

    XCTAssertEqual(events, ["show", "hide-for-capture", "capture", "restore-after-capture"])
  }

  @MainActor
  func testCursorlessRequestDoesNotHideAnExistingCursor() {
    var events: [String] = []
    let cursor = FakeCursorOverlay(events: { events.append($0) })
    let pilot = AccessibilityPilot(
      cursorOverlay: cursor,
      initialCursorPresenter: { cursor.showAtMainScreenCenter() }
    )

    _ = pilot.handle(PilotRequest(id: "show", command: "ping"))
    _ = pilot.handle(PilotRequest(
      id: "background-status",
      command: "status",
      arguments: ["showCursor": .bool(false)]
    ))

    XCTAssertEqual(events, ["show"])
  }

  @MainActor
  func testRequestCanSuppressTheComputerUseCursor() {
    var presentationCount = 0
    let pilot = AccessibilityPilot(initialCursorPresenter: { presentationCount += 1 })

    _ = pilot.handle(PilotRequest(
      id: "background-state",
      command: "get_app_state",
      arguments: ["showCursor": .bool(false), "includeScreenshot": .bool(false)]
    ))

    XCTAssertEqual(presentationCount, 0)
  }

  func testDecodesRequestWithArguments() throws {
    let data = #"{"id":"abc","command":"get_app_state","arguments":{"maxDepth":2,"app":"Finder"}}"#.data(using: .utf8)!
    let request = try JSONDecoder().decode(PilotRequest.self, from: data)

    XCTAssertEqual(request.id, "abc")
    XCTAssertEqual(request.command, "get_app_state")
    XCTAssertEqual(request.arguments["maxDepth"]?.intValue, 2)
    XCTAssertEqual(request.arguments["app"]?.stringValue, "Finder")
  }

  @MainActor
  func testFindAppsRejectsOutOfRangeIntegerWithoutCrashing() throws {
    let data = #"{"id":"overflow","command":"find_apps","arguments":{"maxResults":1e100}}"#.data(using: .utf8)!
    let request = try JSONDecoder().decode(PilotRequest.self, from: data)
    let pilot = AccessibilityPilot(initialCursorPresenter: {})

    let response = pilot.handle(request)

    XCTAssertEqual(response.id, "overflow")
    XCTAssertEqual(response.ok, false)
    XCTAssertEqual(response.error?.code, "invalid_request")
    XCTAssertEqual(response.error?.message, "maxResults must be an integer.")
  }

  func testIntegerValueRequiresAnExactlyRepresentableInteger() {
    XCTAssertEqual(JSONValue.number(42).intValue, 42)
    XCTAssertNil(JSONValue.number(1.5).intValue)
    XCTAssertNil(JSONValue.number(1e100).intValue)
    XCTAssertNil(JSONValue.number(.infinity).intValue)
  }

  @MainActor
  func testMalformedPIDDoesNotFallBackToTheFrontmostApplication() {
    let pilot = AccessibilityPilot(initialCursorPresenter: {})

    for pid in [JSONValue.number(1e100), .number(Double(Int32.max) + 1)] {
      let response = pilot.handle(
        PilotRequest(id: "invalid-pid", command: "focus_app", arguments: ["pid": pid, "window_id": .number(1)])
      )

      XCTAssertEqual(response.ok, true)
      XCTAssertEqual(response.result?.objectValue?["success"]?.boolValue, false)
      XCTAssertEqual(response.result?.objectValue?["errorCode"]?.stringValue, "invalid_request")
    }
  }

  func testDecodesSelectTextRequestWithElementPath() throws {
    let data = #"{"id":"path-1","command":"select_text","arguments":{"path":"root.children[0].children[1]","text":"hello"}}"#.data(using: .utf8)!
    let request = try JSONDecoder().decode(PilotRequest.self, from: data)

    XCTAssertEqual(request.command, "select_text")
    XCTAssertEqual(request.arguments["path"]?.stringValue, "root.children[0].children[1]")
    XCTAssertEqual(request.arguments["text"]?.stringValue, "hello")
  }

  func testRunnerReturnsHandlerResponseAsJsonLine() throws {
    let runner = StdioPilotRunner { request in
      .success(id: request.id, result: .object(["echo": .string(request.command)]))
    }

    let line = runner.handleLine(#"{"id":"1","command":"ping"}"#)
    let response = try JSONDecoder().decode(PilotResponse.self, from: line.data(using: .utf8)!)

    XCTAssertEqual(response.id, "1")
    XCTAssertEqual(response.ok, true)
    XCTAssertEqual(response.result, .object(["echo": .string("ping")]))
  }

  @MainActor
  func testMainThreadRunnerHandlesRequestOnTheMainThread() throws {
    let runner = StdioPilotRunner(handler: { request in
      XCTAssertTrue(Thread.isMainThread)
      return .success(id: request.id, result: .object(["handled": .bool(true)]))
    }, runHandlerOnMainThread: true)

    let line = runner.handleLine(#"{"id":"main","command":"ping"}"#)
    let response = try JSONDecoder().decode(PilotResponse.self, from: line.data(using: .utf8)!)

    XCTAssertEqual(response.id, "main")
    XCTAssertEqual(response.result, .object(["handled": .bool(true)]))
  }

  func testRunnerRejectsInvalidJson() throws {
    let runner = StdioPilotRunner { request in
      .success(id: request.id, result: .object([:]))
    }

    let line = runner.handleLine("not json")
    let response = try JSONDecoder().decode(PilotResponse.self, from: line.data(using: .utf8)!)

    XCTAssertEqual(response.ok, false)
    XCTAssertEqual(response.error?.code, "invalid_request")
  }

  @MainActor
  func testStatusDoesNotRequireAccessibilityPermission() throws {
    let pilot = AccessibilityPilot(initialCursorPresenter: {})

    let response = pilot.handle(PilotRequest(id: "status-1", command: "status"))

    XCTAssertEqual(response.id, "status-1")
    XCTAssertEqual(response.ok, true)
    XCTAssertNotNil(response.result?.objectValue?["accessibilityTrusted"]?.boolValue)
    XCTAssertNotNil(response.result?.objectValue?["screenCaptureTrusted"]?.boolValue)
    XCTAssertEqual(response.result?.objectValue?["version"]?.stringValue, "2.0.2")
    XCTAssertNil(response.result?.objectValue?["protocol"])
  }

  @MainActor
  func testRemovedLegacyCommandsAreUnknown() {
    let pilot = AccessibilityPilot(initialCursorPresenter: {})
    for command in ["focused", "snapshot", "perform"] {
      let response = pilot.handle(PilotRequest(id: command, command: command))
      XCTAssertFalse(response.ok)
      XCTAssertEqual(response.error?.code, "unknown_command")
    }
  }
}

@MainActor
private final class FakeScreenCapturer: ScreenCapturing {
  var isTrusted = true
  var requestResult = true
  var requestCount = 0
  var screenDisplayIdentifiers: [CGDirectDisplayID?] = []
  var windowProcessIdentifiers: [pid_t] = []
  private let onCapture: () -> Void

  init(onCapture: @escaping () -> Void = {}) {
    self.onCapture = onCapture
  }

  func requestAccess() -> Bool {
    requestCount += 1
    return requestResult
  }

  func captureScreen(displayID: CGDirectDisplayID?) throws -> JSONValue {
    onCapture()
    screenDisplayIdentifiers.append(displayID)
    return .object(["scope": .string("screen"), "success": .bool(true)])
  }

  func captureWindow(application: NSRunningApplication, target: WindowCaptureTarget) throws -> JSONValue {
    onCapture()
    windowProcessIdentifiers.append(application.processIdentifier)
    return .object(["scope": .string("window"), "success": .bool(true)])
  }
}

@MainActor
private func fakeWindowTargets(pid: pid_t) -> WindowTargeting {
  let window = AXUIElementCreateSystemWide()
  let targeting = WindowTargeting(attributeReader: { _, attribute in
    switch attribute {
    case kAXWindowsAttribute: return [window] as CFArray
    case kAXFocusedWindowAttribute: return window
    case kAXTitleAttribute: return "Test window" as CFString
    case kAXPositionAttribute:
      var point = CGPoint(x: 10, y: 20)
      return AXValueCreate(.cgPoint, &point)
    case kAXSizeAttribute:
      var size = CGSize(width: 800, height: 600)
      return AXValueCreate(.cgSize, &size)
    default: return nil
    }
  })
  _ = targeting.list(app: AXUIElementCreateApplication(pid), pid: pid)
  return targeting
}

@MainActor
private final class FakeCursorOverlay: ComputerUseCursorPresenting {
  private let events: (String) -> Void

  init(events: @escaping (String) -> Void) {
    self.events = events
  }

  func showAtMainScreenCenter() {
    events("show")
  }

  func hideForCapture() -> Bool {
    events("hide-for-capture")
    return true
  }

  func restoreAfterCapture(_ shouldRestore: Bool) {
    if shouldRestore {
      events("restore-after-capture")
    }
  }

  func showClick(at _: CGPoint) -> TimeInterval {
    0
  }
}
