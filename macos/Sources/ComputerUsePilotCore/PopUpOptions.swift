import ApplicationServices
import CoreGraphics
import Foundation

/// A pop-up button (an AppKit NSPopUpButton or a web <select>) exposes its
/// choices only while its menu is open. The menu is opened for an instant to
/// read them, then closed; the user's front app is kept in front throughout.
enum PopUpOptions {
  /// Where to click a <select>'s label: its center, or, when the label wraps
  /// the control, the label's own text beside it. Nil when no such strip exists.
  static func labelClickPoint(label: CGRect, control: CGRect) -> CGPoint? {
    guard label.intersects(control) else { return CGPoint(x: label.midX, y: label.midY) }
    let left = control.minX - label.minX
    let right = label.maxX - control.maxX
    if left >= 8 { return CGPoint(x: label.minX + left / 2, y: control.midY) }
    if right >= 8 { return CGPoint(x: control.maxX + right / 2, y: control.midY) }
    return nil
  }

  static func line(_ line: String, options: [String]) -> String {
    "\(line) options=\(options.joined(separator: "|"))"
  }

  static func matchingIndex(of option: String, in titles: [String]) -> Int? {
    titles.firstIndex { titleMatches($0, option) }
  }

  static func titleMatches(_ title: String?, _ option: String) -> Bool {
    title?.trimmingCharacters(in: .whitespaces)
      .caseInsensitiveCompare(option.trimmingCharacters(in: .whitespaces)) == .orderedSame
  }

  /// AppKit puts the open menu under the button; WebKit adds a new menu
  /// elsewhere in the page.
  static func openedMenu(ownMenus: [AXUIElement], before: [AXUIElement], after: [AXUIElement]) -> AXUIElement? {
    ownMenus.first ?? after.first { menu in !before.contains { CFEqual($0, menu) } }
  }

  struct Menu {
    let menu: AXUIElement
    let items: [(title: String, element: AXUIElement)]
  }

  /// Opens the button's menu and returns it with its items, still open.
  @MainActor
  static func open(_ button: AXUIElement, window: AXUIElement, pid: pid_t,
    front: SyntheticAppFocus.FrontSnapshot? = nil) -> Menu? {
    // AppKit and Chrome open the menu under the button; Safari adds it
    // elsewhere in the page, which only a (slow) page search finds. A button
    // with children of its own keeps its menu there.
    let searchesPage = children(button).isEmpty
    let before = searchesPage ? menus(in: window) : []
    guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return nil }
    // Opening the menu orders the app's window group above the user's window;
    // put the user's window back the moment that happens.
    let deadline = Date().addingTimeInterval(1.0)
    var nextSearch = Date()
    var nextPageSearch = Date()
    var firstSeen: Date?
    var opened: AXUIElement?
    while Date() < deadline {
      front?.restoreIfTaken()
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
      guard Date() >= nextSearch else { continue }
      nextSearch = Date().addingTimeInterval(0.02)
      let own = children(button).filter { role($0) == kAXMenuRole }
      var after: [AXUIElement] = []
      if own.isEmpty, searchesPage, Date() >= nextPageSearch {
        after = menus(in: window)
        nextPageSearch = Date().addingTimeInterval(0.03)
      }
      guard let menu = openedMenu(ownMenus: own, before: before, after: after) else { continue }
      opened = menu
      // Chrome names its items by value until it fills in their titles.
      let items = children(menu).filter { role($0) == kAXMenuItemRole }.compactMap { item -> (title: String, element: AXUIElement)? in
        let title = string(item, kAXTitleAttribute)
        guard let name = title?.isEmpty == false ? title : string(item, kAXValueAttribute) ?? title else { return nil }
        return (title: name, element: item)
      }
      guard !items.isEmpty else { continue }
      // Chrome adds the items before their titles; give the titles a moment.
      let seen = firstSeen ?? Date()
      firstSeen = seen
      if ready(titles: items.map(\.title), waited: Date().timeIntervalSince(seen)) { return Menu(menu: menu, items: items) }
    }
    // Never leave a menu open, even one that was not recognized.
    if let opened {
      close(opened, of: button, pid: pid)
    } else if isExpanded(button) == true {
      for event in (try? KeyboardChord.parse("Escape").events()) ?? [] { event.postToPid(pid) }
    }
    return nil
  }

  /// Item titles can be read once none is empty, or once they had time to fill in.
  static func ready(titles: [String], waited: TimeInterval) -> Bool {
    !titles.isEmpty && (!titles.contains { $0.isEmpty } || (waited >= 0.2 && titles.contains { !$0.isEmpty }))
  }

  /// Reads the button's choices: opens its menu, reads, closes it.
  @MainActor
  static func options(of button: AXUIElement, window: AXUIElement, pid: pid_t) -> [String]? {
    let front = SyntheticAppFocus.FrontSnapshot.capture()
    defer { front.restoreSettled() }
    guard let menu = open(button, window: window, pid: pid, front: front) else { return nil }
    close(menu.menu, of: button, pid: pid)
    return menu.items.map(\.title)
  }

  /// Cancels the menu and confirms it closed; Chrome can ignore a cancel sent
  /// while its menu is still opening.
  @MainActor
  static func close(_ menu: AXUIElement, of button: AXUIElement, pid: pid_t) {
    for attempt in 0..<4 {
      if attempt == 3 || AXUIElementPerformAction(menu, kAXCancelAction as CFString) != .success {
        for event in (try? KeyboardChord.parse("Escape").events()) ?? [] { event.postToPid(pid) }
      }
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
      if !isOpen(menu, of: button) { return }
    }
  }

  /// The button says whether it is expanded when it can (web pop-ups);
  /// otherwise a closed menu leaves the tree.
  private static func isOpen(_ menu: AXUIElement, of button: AXUIElement) -> Bool {
    if let expanded = isExpanded(button) { return expanded }
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(menu, kAXRoleAttribute as CFString, &value) == .success
  }

  private static func isExpanded(_ button: AXUIElement) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(button, "AXExpanded" as CFString, &value) == .success else { return nil }
    return value as? Bool
  }

  /// Menus in the window, without descending into them. Bounded for large pages.
  private static func menus(in window: AXUIElement) -> [AXUIElement] {
    var found: [AXUIElement] = []
    var queue = children(window)
    var visited = 0
    while !queue.isEmpty, visited < 4000 {
      let element = queue.removeFirst()
      visited += 1
      if role(element) == kAXMenuRole { found.append(element); continue }
      queue.append(contentsOf: children(element))
    }
    return found
  }

  private static func children(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
    return value as? [AXUIElement] ?? []
  }

  private static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute) }

  private static func string(_ element: AXUIElement, _ name: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as? String
  }
}
