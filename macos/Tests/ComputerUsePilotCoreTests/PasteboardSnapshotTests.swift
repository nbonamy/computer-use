import AppKit
import XCTest
@testable import ComputerUsePilotCore

final class PasteboardSnapshotTests: XCTestCase {
  func testTemporaryContentsRestoreImagesFilesAndCustomBinaryDataByteForByte() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("computer-use-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.setColor(NSColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1), atX: 0, y: 0)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    let tiff = try XCTUnwrap(bitmap.tiffRepresentation)
    let image = NSPasteboardItem()
    image.setData(png, forType: .png)
    image.setData(tiff, forType: .tiff)
    let customType = NSPasteboard.PasteboardType("com.example.custom-binary")
    let binary = Data([0, 255, 128, 0, 42])
    let rtf = Data("{\\rtf1\\ansi Rich \\b text}".utf8)
    let file = NSPasteboardItem()
    file.setString("file:///tmp/example.pdf", forType: .fileURL)
    file.setData(binary, forType: customType)
    file.setData(rtf, forType: .rtf)
    XCTAssertTrue(pasteboard.writeObjects([image, file]))
    let temporary = NSPasteboardItem()
    temporary.setString("text to insert", forType: .string)

    let restored = try PasteboardSnapshot.withTemporaryContents([temporary], on: pasteboard) {
      XCTAssertEqual(pasteboard.string(forType: .string), "text to insert")
    }

    XCTAssertTrue(restored)
    let items = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(items.count, 2)
    let restoredImage = try XCTUnwrap(items.first)
    XCTAssertEqual(Set(restoredImage.types), Set([.png, .tiff]))
    XCTAssertEqual(restoredImage.data(forType: .png), png)
    XCTAssertEqual(restoredImage.data(forType: .tiff), tiff)
    let restoredFile = try XCTUnwrap(items.last)
    // macOS may derive additional plain-text formats from RTF.
    XCTAssertTrue(Set([.fileURL, customType, .rtf]).isSubset(of: Set(restoredFile.types)))
    XCTAssertEqual(restoredFile.string(forType: .fileURL), "file:///tmp/example.pdf")
    XCTAssertEqual(restoredFile.data(forType: customType), binary)
    XCTAssertEqual(restoredFile.data(forType: .rtf), rtf)
  }

  func testTemporaryContentsRestoreAnEmptyClipboard() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("computer-use-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    let temporary = NSPasteboardItem()
    temporary.setString("temporary", forType: .string)

    XCTAssertTrue(try PasteboardSnapshot.withTemporaryContents([temporary], on: pasteboard) {})
    XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
  }

  func testUnreadableClipboardFormatAbortsBeforeOverwritingAnything() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("computer-use-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let unreadableType = NSPasteboard.PasteboardType("com.example.unavailable-data")
    pasteboard.declareTypes([.string, unreadableType], owner: nil)
    pasteboard.setString("keep me", forType: .string)
    XCTAssertNil(pasteboard.data(forType: unreadableType))
    let originalChangeCount = pasteboard.changeCount
    let temporary = NSPasteboardItem()
    temporary.setString("temporary", forType: .string)
    var delivered = false

    XCTAssertThrowsError(try PasteboardSnapshot.withTemporaryContents([temporary], on: pasteboard) {
      delivered = true
    }) { error in
      XCTAssertEqual((error as? PilotRuntimeError)?.code, "clipboard_snapshot_failed")
    }

    XCTAssertFalse(delivered)
    XCTAssertEqual(pasteboard.changeCount, originalChangeCount)
    XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    XCTAssertTrue(pasteboard.types?.contains(unreadableType) == true)
  }

  func testTemporaryContentsDeliverLongUnicodeTextInOneOperationAndRestoreClipboard() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("computer-use-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let original = NSPasteboardItem()
    original.setString("original", forType: .string)
    original.setString("<b>original</b>", forType: .html)
    pasteboard.writeObjects([original])
    let text = String(repeating: "Bonjour 👩🏽‍💻\t世界\n", count: 1000)
    let temporary = NSPasteboardItem()
    temporary.setString(text, forType: .string)
    var pasteCount = 0

    let restored = try PasteboardSnapshot.withTemporaryContents([temporary], on: pasteboard) {
      pasteCount += 1
      XCTAssertEqual(pasteboard.string(forType: .string), text)
      XCTAssertNil(pasteboard.string(forType: .html))
    }

    XCTAssertEqual(pasteCount, 1)
    XCTAssertTrue(restored)
    XCTAssertEqual(pasteboard.string(forType: .string), "original")
    XCTAssertEqual(pasteboard.string(forType: .html), "<b>original</b>")
  }

  func testTemporaryContentsPreserveConcurrentClipboardChanges() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("computer-use-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("original", forType: .string)
    let temporary = NSPasteboardItem()
    temporary.setString("temporary", forType: .string)

    let restored = try PasteboardSnapshot.withTemporaryContents([temporary], on: pasteboard) {
      pasteboard.clearContents()
      pasteboard.setString("new user copy", forType: .string)
    }

    XCTAssertFalse(restored)
    XCTAssertEqual(pasteboard.string(forType: .string), "new user copy")
  }

  func testTemporaryContentsRestoreClipboardWhenDeliveryFails() {
    enum DeliveryError: Error { case targetLostFocus }
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("computer-use-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.setString("original", forType: .string)
    let temporary = NSPasteboardItem()
    temporary.setString("temporary", forType: .string)

    XCTAssertThrowsError(try PasteboardSnapshot.withTemporaryContents([temporary], on: pasteboard) {
      throw DeliveryError.targetLostFocus
    })
    XCTAssertEqual(pasteboard.string(forType: .string), "original")
  }

  func testRestoresAllCapturedItemsAndTypes() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("computer-use-tests-\(UUID().uuidString)"))
    let first = NSPasteboardItem()
    first.setString("plain", forType: .string)
    first.setString("<b>plain</b>", forType: .html)
    let second = NSPasteboardItem()
    second.setString("second", forType: .string)
    pasteboard.writeObjects([first, second])
    let snapshot = try PasteboardSnapshot(pasteboard: pasteboard)

    pasteboard.clearContents()
    pasteboard.setString("temporary", forType: .string)
    try snapshot.restore(to: pasteboard)

    let items = try XCTUnwrap(pasteboard.pasteboardItems)
    XCTAssertEqual(items.count, 2)
    XCTAssertEqual(items[0].string(forType: .string), "plain")
    XCTAssertEqual(items[0].string(forType: .html), "<b>plain</b>")
    XCTAssertEqual(items[1].string(forType: .string), "second")
  }
}
