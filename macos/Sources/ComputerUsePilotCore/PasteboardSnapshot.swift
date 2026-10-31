import AppKit

struct PasteboardSnapshot {
  /// Restore only while the clipboard still contains the contents we wrote.
  /// The operation must wait for the target to consume them before returning.
  static func withTemporaryContents(
    _ contents: [NSPasteboardItem],
    on pasteboard: NSPasteboard,
    operation: () throws -> Void
  ) throws -> Bool {
    let snapshot = try PasteboardSnapshot(pasteboard: pasteboard)
    pasteboard.clearContents()
    var ownedChangeCount = pasteboard.changeCount
    do {
      let written = pasteboard.writeObjects(contents)
      ownedChangeCount = pasteboard.changeCount
      guard written else {
        throw PilotRuntimeError(code: "clipboard_write_failed", message: "Unable to write text to the clipboard; no paste was sent.")
      }
      try operation()
    } catch {
      if pasteboard.changeCount == ownedChangeCount {
        try snapshot.restore(to: pasteboard)
      }
      throw error
    }
    guard pasteboard.changeCount == ownedChangeCount else {
      return false
    }
    try snapshot.restore(to: pasteboard)
    return true
  }

  private struct Item {
    let values: [(type: NSPasteboard.PasteboardType, data: Data)]
  }

  private let items: [Item]

  init(pasteboard: NSPasteboard) throws {
    let originalChangeCount = pasteboard.changeCount
    let sourceItems = pasteboard.pasteboardItems ?? []
    guard !sourceItems.isEmpty || (pasteboard.types ?? []).isEmpty else {
      throw PilotRuntimeError(code: "clipboard_snapshot_failed", message: "Unable to read clipboard items; the clipboard was left unchanged.")
    }
    items = try sourceItems.map { item in
      Item(values: try item.types.map { type in
        guard let data = item.data(forType: type) else {
          throw PilotRuntimeError(code: "clipboard_snapshot_failed", message: "Unable to preserve clipboard format \(type.rawValue); the clipboard was left unchanged.")
        }
        return (type, data)
      })
    }
    guard pasteboard.changeCount == originalChangeCount else {
      throw PilotRuntimeError(code: "clipboard_snapshot_failed", message: "The clipboard changed while being saved; no paste was sent.")
    }
  }

  func restore(to pasteboard: NSPasteboard) throws {
    let restored = try items.map { snapshot in
      let item = NSPasteboardItem()
      for value in snapshot.values {
        guard item.setData(value.data, forType: value.type) else {
          throw PilotRuntimeError(code: "clipboard_restore_failed", message: "Unable to recreate a saved clipboard format.")
        }
      }
      return item
    }
    pasteboard.clearContents()
    if !restored.isEmpty, !pasteboard.writeObjects(restored) {
      throw PilotRuntimeError(code: "clipboard_restore_failed", message: "Unable to restore the saved clipboard contents.")
    }
  }
}
