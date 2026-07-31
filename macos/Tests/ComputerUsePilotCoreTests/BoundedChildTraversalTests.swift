import XCTest

@testable import ComputerUsePilotCore

final class BoundedChildTraversalTests: XCTestCase {
  func testStopsAfterBudgetExhaustionAndAddsOneMarker() {
    var remaining: Int? = 2
    var visited: [Int] = []

    let nodes = boundedChildNodes([0, 1, 2, 3], remaining: &remaining) { child, _, remaining in
      visited.append(child)
      remaining? -= 1
      return .number(Double(child))
    }

    XCTAssertEqual(visited, [0, 1])
    XCTAssertEqual(
      nodes,
      [
        .number(0),
        .number(1),
        .object(["truncated": .bool(true)]),
      ])
  }

  func testVisitsAllChildrenWithoutABudget() {
    var remaining: Int?
    var visited: [Int] = []

    let nodes = boundedChildNodes([0, 1, 2], remaining: &remaining) { child, _, _ in
      visited.append(child)
      return .number(Double(child))
    }

    XCTAssertEqual(visited, [0, 1, 2])
    XCTAssertEqual(nodes, [.number(0), .number(1), .number(2)])
  }
}
