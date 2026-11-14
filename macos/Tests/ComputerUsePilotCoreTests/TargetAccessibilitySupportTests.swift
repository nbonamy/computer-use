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

  /// Chrome rejects AXManualAccessibility; its full web tree needs the
  /// assistive-technology flag, which is handed back when the helper exits.
  func testChromiumBrowsersGetTheAssistiveTechnologyFlagAndLoseItOnRestore() {
    var flags: [(pid_t, Bool)] = []
    var browserWaits = 0
    let support = TargetAccessibilitySupport(
      setManualAccessibility: { _, _ in .attributeUnsupported },
      setEnhancedInterface: { pid, enabled in flags.append((pid, enabled)); return true },
      isChromiumBrowser: { $0 == 42 },
      waitForTree: {},
      waitForBrowserTree: { browserWaits += 1 }
    )

    XCTAssertEqual(support.prepare(processIdentifier: 42), .enabled)
    XCTAssertEqual(support.prepare(processIdentifier: 42), .enabled)
    XCTAssertEqual(support.prepare(processIdentifier: 7), .unsupported)
    XCTAssertEqual(browserWaits, 1)
    support.restore()
    XCTAssertEqual(flags.map { "\($0.0):\($0.1)" }, ["42:true", "42:false"])
  }

  func testChromiumBundlesAreTheBrowsersNotElectronApps() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    func bundle(_ name: String, framework: String) throws -> URL {
      let url = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Frameworks/\(framework)"),
        withIntermediateDirectories: true)
      return url
    }
    XCTAssertTrue(TargetAccessibilitySupport.isChromiumBundle(try bundle("Chrome.app", framework: "Google Chrome Framework.framework")))
    XCTAssertFalse(TargetAccessibilitySupport.isChromiumBundle(try bundle("Slack.app", framework: "Electron Framework.framework")))
    XCTAssertFalse(TargetAccessibilitySupport.isChromiumBundle(try bundle("Notes.app", framework: "Sparkle.framework")))
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
