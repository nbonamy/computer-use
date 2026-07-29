import XCTest
@testable import ComputerUsePilotCore

final class PilotProtocolTests: XCTestCase {
  func testCursorAnimationDurationScalesAndStaysWithinHumanMovementBounds() {
    XCTAssertEqual(computerUseCursorAnimationDuration(for: 10), 0.16)
    XCTAssertEqual(computerUseCursorAnimationDuration(for: 700), 0.5)
    XCTAssertEqual(computerUseCursorAnimationDuration(for: 2_000), 0.55)
  }

  func testDecodesRequestWithArguments() throws {
    let data = #"{"id":"abc","command":"snapshot","arguments":{"maxDepth":2,"app":"Finder"}}"#.data(using: .utf8)!
    let request = try JSONDecoder().decode(PilotRequest.self, from: data)

    XCTAssertEqual(request.id, "abc")
    XCTAssertEqual(request.command, "snapshot")
    XCTAssertEqual(request.arguments["maxDepth"]?.intValue, 2)
    XCTAssertEqual(request.arguments["app"]?.stringValue, "Finder")
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
    let pilot = AccessibilityPilot()

    let response = pilot.handle(PilotRequest(id: "status-1", command: "status"))

    XCTAssertEqual(response.id, "status-1")
    XCTAssertEqual(response.ok, true)
    XCTAssertNotNil(response.result?.objectValue?["accessibilityTrusted"]?.boolValue)
    XCTAssertEqual(response.result?.objectValue?["protocol"]?.stringValue, "computer-use-pilot.v1")
  }
}
