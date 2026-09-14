import AppKit
import XCTest
@testable import ComputerUsePilotCore

final class PasteboardSnapshotTests: XCTestCase {
  func testRestoresAllCapturedItemsAndTypes() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("computer-use-tests-\(UUID().uuidString)"))
    let first = NSPasteboardItem()
    first.setString("plain", forType: .string)
    first.setString("<b>plain</b>", forType: .html)
    let second = NSPasteboardItem()
    second.setString("second", forType: .string)
    pasteboard.writeObjects([first, second])
    let snapshot = PasteboardSnapshot(pasteboard: pasteboard)

    pasteboard.clearContents()
    pasteboard.setString("temporary", forType: .string)
    snapshot.restore(to: pasteboard)

    let items = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].string(forType: .string), "plain")
    XCTAssertEqual(items[0].string(forType: .html), "<b>plain</b>")
    XCTAssertEqual(items[1].string(forType: .string), "second")
  }
}
