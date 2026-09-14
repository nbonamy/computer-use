import AppKit

struct PasteboardSnapshot {
  private struct Item {
    let values: [(type: NSPasteboard.PasteboardType, data: Data)]
  }

  private let items: [Item]

  init(pasteboard: NSPasteboard) {
    items = (pasteboard.pasteboardItems ?? []).map { item in
      Item(values: item.types.compactMap { type in
        item.data(forType: type).map { (type, $0) }
      })
    }
  }

  func restore(to pasteboard: NSPasteboard) {
    pasteboard.clearContents()
    let restored = items.map { snapshot in
      let item = NSPasteboardItem()
      for value in snapshot.values {
        item.setData(value.data, forType: value.type)
      }
      return item
    }
    if !restored.isEmpty {
      pasteboard.writeObjects(restored)
    }
  }
}
