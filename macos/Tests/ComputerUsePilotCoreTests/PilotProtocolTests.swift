import XCTest
@testable import ComputerUsePilotCore

final class PilotProtocolTests: XCTestCase {
  func testCursorAnimationDurationScalesAndStaysWithinHumanMovementBounds() {
    XCTAssertEqual(computerUseCursorAnimationDuration(for: 10), 0.16)
    XCTAssertEqual(computerUseCursorAnimationDuration(for: 700), 0.5)
    XCTAssertEqual(computerUseCursorAnimationDuration(for: 2_000), 0.55)
  }

  @MainActor
  func testPilotPresentsTheInitialCursorOnlyOnTheFirstRequest() {
    var presentationCount = 0
    let pilot = AccessibilityPilot(initialCursorPresenter: { presentationCount += 1 })

    _ = pilot.handle(PilotRequest(id: "first", command: "ping"))
    _ = pilot.handle(PilotRequest(id: "second", command: "ping"))

    XCTAssertEqual(presentationCount, 1)
  }

  func testDecodesRequestWithArguments() throws {
    let data = #"{"id":"abc","command":"snapshot","arguments":{"maxDepth":2,"app":"Finder"}}"#.data(using: .utf8)!
    let request = try JSONDecoder().decode(PilotRequest.self, from: data)

    XCTAssertEqual(request.id, "abc")
    XCTAssertEqual(request.command, "snapshot")
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
        PilotRequest(id: "invalid-pid", command: "focus_app", arguments: ["pid": pid])
      )

      XCTAssertEqual(response.ok, true)
      XCTAssertEqual(response.result?.objectValue?["success"]?.boolValue, false)
      XCTAssertEqual(response.result?.objectValue?["errorCode"]?.stringValue, "invalid_request")
    }
  }

  func testDecodesPerformRequestWithSnapshotPath() throws {
    let data = #"{"id":"path-1","command":"perform","arguments":{"action":"type_text","path":"root.children[0].children[1]","text":"hello"}}"#.data(using: .utf8)!
    let request = try JSONDecoder().decode(PilotRequest.self, from: data)

    XCTAssertEqual(request.command, "perform")
    XCTAssertEqual(request.arguments["action"]?.stringValue, "type_text")
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
    XCTAssertEqual(response.result?.objectValue?["protocol"]?.stringValue, "computer-use-pilot.v1")
  }
}
