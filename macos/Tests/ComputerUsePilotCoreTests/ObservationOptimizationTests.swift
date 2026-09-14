import XCTest
@testable import ComputerUsePilotCore

final class ObservationOptimizationTests: XCTestCase {
  func testQuietButUnloadedWebDocumentIsNotReady() {
    for (loaded, progress) in [(false, 1.0), (true, 0.6)] {
      var settler = ObservationSettler()
      let busy = ObservationSettler.isLoading(role: "AXWebArea", busy: false, loaded: loaded, progress: progress)
      _ = settler.ready(signature: "page header", busy: busy, elapsed: 0, expected: nil)
      XCTAssertFalse(settler.ready(signature: "page header", busy: busy, elapsed: 2, expected: nil))
    }
    XCTAssertFalse(ObservationSettler.isLoading(role: "AXWebArea", busy: false, loaded: true, progress: 1))
    XCTAssertFalse(ObservationSettler.isLoading(role: "AXWindow", busy: false, loaded: nil, progress: nil))
    XCTAssertTrue(ObservationSettler.isLoading(role: "AXGroup", busy: true, loaded: nil, progress: nil))
  }

  @MainActor
  func testShortProductFactsAreNotDiscardedAsUnconsumedLabels() {
    let pilot = AccessibilityPilot(initialCursorPresenter: {})
    for value in ["$380.87", "In Stock", "Size: Small", "USB-C 60W"] {
      let node: [String: JSONValue] = ["role": .string("AXStaticText"), "value": .string(value), "siblingLabelCaptured": .bool(true)]
      XCTAssertTrue(pilot.shouldRenderStateLine(node, depth: 8, parentRole: "group", includeMacChrome: false), value)
    }
    let empty: [String: JSONValue] = ["role": .string("AXGroup"), "subrole": .string("AXEmptyGroup")]
    XCTAssertFalse(pilot.shouldRenderStateLine(empty, depth: 1, parentRole: "group", includeMacChrome: false))
  }

  func testExpectedTextIsNotHeldHostageByUnrelatedChangingContent() {
    var settler = ObservationSettler()
    XCTAssertFalse(settler.ready(signature: "Added to cart ad 1", busy: false, elapsed: 0, expected: "Added to cart"))
    XCTAssertTrue(settler.ready(signature: "Added to cart ad 2", busy: false, elapsed: 0.5, expected: "Added to cart"))
  }

  func testSettlingRequiresQuietAndNonBusyState() {
    var settler = ObservationSettler()
    XCTAssertFalse(settler.ready(signature: "loading", busy: true, elapsed: 0, expected: nil))
    XCTAssertFalse(settler.ready(signature: "results", busy: false, elapsed: 1, expected: nil))
    XCTAssertTrue(settler.ready(signature: "results", busy: false, elapsed: 1.5, expected: nil))
    XCTAssertFalse(settler.ready(signature: "results", busy: true, elapsed: 2, expected: nil))
  }

  func testExpectedTextDoesNotAcceptUnchangedWrongVariant() {
    var settler = ObservationSettler()
    XCTAssertFalse(settler.ready(signature: "X-Large", busy: false, elapsed: 0, expected: "Small"))
    XCTAssertFalse(settler.ready(signature: "X-Large", busy: false, elapsed: 5, expected: "Small"))
    XCTAssertFalse(settler.ready(signature: "Small", busy: false, elapsed: 6, expected: "Small"))
    XCTAssertTrue(settler.ready(signature: "Small", busy: false, elapsed: 6.5, expected: "Small"))
  }

  @MainActor
  func testUnknownArgumentsFailBeforeCursorOrAccessibilitySideEffects() {
    var effects = 0
    let pilot = AccessibilityPilot(initialCursorPresenter: { effects += 1 })
    let response = pilot.handle(PilotRequest(id: "bad", command: "get_app_state",
      arguments: ["window_id": .number(1), "root_element_index": .number(3)]))
    XCTAssertEqual(response.error?.code, "invalid_request")
    XCTAssertTrue(response.error?.message.contains("root_element_index") == true)
    XCTAssertEqual(effects, 0)
  }

  func testWaitAndTypingOptionsAreValidated() {
    XCTAssertNoThrow(try PilotArguments.validate(command: "type_text", arguments: ["element_index": .number(1), "replace": .bool(true), "submit": .bool(true)]))
    XCTAssertThrowsError(try PilotArguments.validate(command: "type_text", arguments: ["replace": .string("yes")]))
    XCTAssertThrowsError(try PilotArguments.validate(command: "get_app_state", arguments: ["timeoutMs": .number(15001)]))
    XCTAssertThrowsError(try PilotArguments.validate(command: "get_app_state", arguments: ["waitForText": .string("")]))
  }

  @MainActor
  func testDescriptionsOnlyAppearWhenTheyAddInformation() {
    let pilot = AccessibilityPilot(initialCursorPresenter: {})
    let shared: [String: JSONValue] = ["role": .string("AXButton"), "title": .string("Save"), "description": .string("Save")]
    XCTAssertFalse(pilot.elementLine(shared).contains("desc="))
    var distinct = shared
    distinct["description"] = .string("Save draft")
    XCTAssertTrue(pilot.elementLine(distinct).contains("desc=\"Save draft\""))
    let label: [String: JSONValue] = ["role": .string("AXStaticText"), "value": .string("Monitor")]
    XCTAssertFalse(pilot.shouldRenderStateLine(label, depth: 8, parentRole: "link", includeMacChrome: false, ancestorLabels: ["Monitor"]))
    XCTAssertTrue(pilot.shouldRenderStateLine(label, depth: 8, parentRole: "link", includeMacChrome: false, ancestorLabels: ["Different product"]))
    let price: [String: JSONValue] = ["role": .string("AXStaticText"), "value": .string("$380.87")]
    XCTAssertTrue(pilot.shouldRenderStateLine(price, depth: 8, parentRole: "group", includeMacChrome: false, ancestorLabels: ["Monitor"]))
  }

  @MainActor
  func testNavigationUsesSmallerFullStateAndResetsBaseline() {
    let history = AccessibilityStateHistory()
    let row = AccessibilityStateRow(elementIndex: 2, line: "2 button New", parentElementIndex: nil, siblingIndex: 0)
    _ = history.render(key: "a", header: [], rows: [.init(elementIndex: 1, line: "1 old", parentElementIndex: nil, siblingIndex: 0)], footer: [], disableDiff: false)
    let current = history.render(key: "a", header: [], rows: [row], footer: [], disableDiff: false)
    XCTAssertEqual(current.kind, "full")
    XCTAssertEqual(current.text, "2 button New")
    let next = history.render(key: "a", header: [], rows: [row], footer: [], disableDiff: false)
    XCTAssertEqual(next.baseRevision, current.revision)
  }

  @MainActor
  func testRemovedRangesDoNotRepeatDeletedContent() {
    let history = AccessibilityStateHistory()
    let retained = AccessibilityStateRow(elementIndex: 9, line: String(repeating: "retained ", count: 100), parentElementIndex: nil, siblingIndex: 0)
    let old = [1, 2, 3, 5].map { AccessibilityStateRow(elementIndex: $0, line: "obsolete sensitive content", parentElementIndex: nil, siblingIndex: $0) }
    _ = history.render(key: "a", header: [], rows: [retained] + old, footer: [], disableDiff: false)
    let result = history.render(key: "a", header: [], rows: [retained], footer: [], disableDiff: false)
    XCTAssertTrue(result.text.contains("Removed IDs: 1-3, 5"))
    XCTAssertFalse(result.text.contains("obsolete"))
  }
}
