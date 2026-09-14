import XCTest
@testable import ComputerUsePilotCore

@MainActor
final class AccessibilityStateHistoryTests: XCTestCase {
  func testFirstStateIsFullAndSecondStateIsDiff() {
    let history = AccessibilityStateHistory()
    let first = history.render(
      key: "app",
      header: ["header"],
      rows: [row(1, "1 button \"Save\"", 0), row(2, "2 text \"Draft\"", 1)],
      footer: [],
      disableDiff: false
    )
    let second = history.render(
      key: "app",
      header: ["header"],
      rows: [row(1, "1 button \"Save\"", 0), row(2, "2 text \"Saved\"", 1), row(3, "3 image", 2)],
      footer: [],
      disableDiff: false
    )

    XCTAssertEqual(first.kind, "full")
    XCTAssertEqual(second.kind, "diff")
    XCTAssertEqual(second.baseRevision, first.revision)
    XCTAssertTrue(second.text.contains("~ 2 text \"Saved\""))
    XCTAssertTrue(second.text.contains("+ 3 image"))
    XCTAssertFalse(second.text.contains("+ 1 button"))
  }

  func testRemovedAndMovedRowsAreReported() {
    let history = AccessibilityStateHistory()
    _ = history.render(
      key: "app",
      header: [],
      rows: [row(1, "1 first", 0), row(2, "2 second", 1), row(3, "3 third", 2)],
      footer: [],
      disableDiff: false
    )
    let result = history.render(
      key: "app",
      header: [],
      rows: [row(3, "3 third", 0), row(1, "1 first", 1)],
      footer: [],
      disableDiff: false
    )

    XCTAssertEqual(result.kind, "diff")
    XCTAssertTrue(result.text.contains("- 2 second"))
    XCTAssertTrue(result.text.contains("~ 3 third"))
    XCTAssertTrue(result.text.contains("~ 1 first"))
  }

  func testNoChangeIsConcise() {
    let history = AccessibilityStateHistory()
    let rows = [row(8, "8 checkbox \"Enabled\"", 0)]
    _ = history.render(key: "app", header: ["header"], rows: rows, footer: [], disableDiff: false)
    let result = history.render(key: "app", header: ["header"], rows: rows, footer: [], disableDiff: false)

    XCTAssertEqual(result.kind, "diff")
    XCTAssertTrue(result.text.contains("(no accessibility changes)"))
  }

  func testForcedFullStateReplacesBaseline() {
    let history = AccessibilityStateHistory()
    _ = history.render(key: "app", header: [], rows: [row(1, "1 old", 0)], footer: [], disableDiff: false)
    let full = history.render(key: "app", header: [], rows: [row(1, "1 new", 0)], footer: [], disableDiff: true)
    let diff = history.render(key: "app", header: [], rows: [row(1, "1 newest", 0)], footer: [], disableDiff: false)

    XCTAssertEqual(full.kind, "full")
    XCTAssertEqual(diff.baseRevision, full.revision)
  }

  func testTruncatedFullStateDoesNotEstablishADiffBaseline() {
    let history = AccessibilityStateHistory()
    let first = history.render(
      key: "app",
      header: [],
      rows: [row(1, "1 a hierarchy too large for the caller", 0)],
      footer: [],
      disableDiff: false,
      maxTextCharacters: 8
    )
    let second = history.render(
      key: "app",
      header: [],
      rows: [row(1, "1 another hierarchy too large", 0)],
      footer: [],
      disableDiff: false,
      maxTextCharacters: 8
    )

    XCTAssertEqual(first.kind, "full")
    XCTAssertEqual(second.kind, "full")
    XCTAssertNil(second.baseRevision)
  }

  func testDuplicateElementRowsCannotCrashDiffing() {
    let history = AccessibilityStateHistory()
    _ = history.render(
      key: "app",
      header: [],
      rows: [row(7, "7 first path", 0), row(7, "7 repeated path", 1)],
      footer: [],
      disableDiff: false
    )
    let result = history.render(
      key: "app",
      header: [],
      rows: [row(7, "7 current path", 0)],
      footer: [],
      disableDiff: false
    )

    XCTAssertEqual(result.kind, "diff")
    XCTAssertTrue(result.text.contains("~ 7 current path"))
  }

  func testRemovingSiblingDoesNotMarkItsDescendantsMoved() {
    let history = AccessibilityStateHistory()
    _ = history.render(
      key: "app",
      header: [],
      rows: [
        hierarchyRow(1, "1 transient", parent: 0, sibling: 0),
        hierarchyRow(2, "2 window", parent: 0, sibling: 1),
        hierarchyRow(3, "3 button", parent: 2, sibling: 0)
      ],
      footer: [],
      disableDiff: false
    )
    let result = history.render(
      key: "app",
      header: [],
      rows: [
        hierarchyRow(2, "2 window", parent: 0, sibling: 0),
        hierarchyRow(3, "3 button", parent: 2, sibling: 0)
      ],
      footer: [],
      disableDiff: false
    )

    XCTAssertTrue(result.text.contains("- 1 transient"))
    XCTAssertTrue(result.text.contains("~ 2 window"))
    XCTAssertFalse(result.text.contains("~ 3 button"))
  }

  private func row(_ id: Int, _ line: String, _ siblingIndex: Int) -> AccessibilityStateRow {
    hierarchyRow(id, line, parent: nil, sibling: siblingIndex)
  }

  private func hierarchyRow(_ id: Int, _ line: String, parent: Int?, sibling: Int) -> AccessibilityStateRow {
    AccessibilityStateRow(
      elementIndex: id,
      line: line,
      parentElementIndex: parent,
      siblingIndex: sibling
    )
  }
}
