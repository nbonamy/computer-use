import ApplicationServices
import XCTest
@testable import ComputerUsePilotCore

final class TargetAccessibilitySupportTests: XCTestCase {
  func testEnablesManualAccessibilityOncePerTargetProcess() {
    var requests: [(pid_t, Bool)] = []
    var waitCount = 0
    let support = TargetAccessibilitySupport(
      setManualAccessibility: { pid, enabled in
        requests.append((pid, enabled))
        return .success
      },
      waitForTree: { waitCount += 1 }
    )

    XCTAssertEqual(support.prepare(processIdentifier: 42), .enabled)
    XCTAssertEqual(support.prepare(processIdentifier: 42), .enabled)
    XCTAssertEqual(requests.map { $0.0 }, [42])
    XCTAssertEqual(requests.map { $0.1 }, [true])
    XCTAssertEqual(waitCount, 1)
  }

  func testCachesUnsupportedTargetsWithoutWaiting() {
    var requestCount = 0
    var waitCount = 0
    let support = TargetAccessibilitySupport(
      setManualAccessibility: { _, _ in
        requestCount += 1
        return .attributeUnsupported
      },
      waitForTree: { waitCount += 1 }
    )

    XCTAssertEqual(support.prepare(processIdentifier: 42), .unsupported)
    XCTAssertEqual(support.prepare(processIdentifier: 42), .unsupported)
    XCTAssertEqual(requestCount, 1)
    XCTAssertEqual(waitCount, 0)
  }

  func testRetriesTransientFailures() {
    var requestCount = 0
    let support = TargetAccessibilitySupport(
      setManualAccessibility: { _, _ in
        requestCount += 1
        return requestCount == 1 ? .cannotComplete : .success
      },
      waitForTree: {}
    )

    XCTAssertEqual(support.prepare(processIdentifier: 42), .failed)
    XCTAssertEqual(support.prepare(processIdentifier: 42), .enabled)
    XCTAssertEqual(requestCount, 2)
  }
}
