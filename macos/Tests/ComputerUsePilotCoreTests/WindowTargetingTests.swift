import CoreGraphics
import ApplicationServices
import XCTest
@testable import ComputerUsePilotCore

final class WindowTargetingTests: XCTestCase {
  /// Sandboxed Open/Save panels draw their content in a separate system
  /// service; the app only owns an empty placeholder sheet.
  @MainActor
  func testRemotePanelKeysGoToTheProcessThatDrawsTheSheetContent() {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let sheet = AXUIElementCreateApplication(103)
    let content = AXUIElementCreateApplication(104)
    let targeting = WindowTargeting(attributeReader: { element, name in
      if CFEqual(element, app), name == kAXFocusedWindowAttribute { return sheet }
      if CFEqual(element, sheet), name == kAXRoleAttribute { return kAXSheetRole as CFString }
      if CFEqual(element, sheet), name == kAXParentAttribute { return parent }
      if CFEqual(element, sheet), name == kAXChildrenAttribute { return [content] as CFArray }
      return nil
    }, windowOwner: { element in
      if CFEqual(element, sheet) { return 900 }
      if CFEqual(element, content) { return 950 }
      return nil
    })
    XCTAssertEqual(targeting.keyboardProcess(parent, app: app, appPID: 900), 950)
  }

  /// A freshly opened remote panel has no keyboard focus; a click on one of
  /// its labels gives it focus without selecting a file.
  @MainActor
  func testRemotePanelWithoutFocusOffersALabelToClick() {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let sheet = AXUIElementCreateApplication(103)
    let list = AXUIElementCreateApplication(104)
    let label = AXUIElementCreateApplication(105)
    var focused: AXUIElement?
    let targeting = WindowTargeting(attributeReader: { element, name in
      if CFEqual(element, app), name == kAXFocusedWindowAttribute { return sheet }
      if CFEqual(element, app), name == kAXFocusedUIElementAttribute { return focused }
      if CFEqual(element, sheet), name == kAXRoleAttribute { return kAXSheetRole as CFString }
      if CFEqual(element, sheet), name == kAXParentAttribute { return parent }
      if CFEqual(element, sheet), name == kAXChildrenAttribute { return [list, label] as CFArray }
      if CFEqual(element, list), name == kAXRoleAttribute { return kAXListRole as CFString }
      if CFEqual(element, list), name == kAXParentAttribute { return sheet }
      if CFEqual(element, label), name == kAXRoleAttribute { return kAXStaticTextRole as CFString }
      return nil
    }, windowOwner: { element in CFEqual(element, sheet) ? 900 : 950 })
    XCTAssertTrue(targeting.remotePanelFocusTarget(parent, app: app, panelPID: 950).map { CFEqual($0, label) } ?? false)
    focused = list
    XCTAssertNil(targeting.remotePanelFocusTarget(parent, app: app, panelPID: 950))
  }

  /// Return on a background panel's file list confirms through the panel's
  /// enabled OKButton; inside a text field it stays an ordinary key.
  @MainActor
  func testReturnConfirmsThroughTheRemotePanelOKButtonOutsideTextFields() {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let sheet = AXUIElementCreateApplication(103)
    let list = AXUIElementCreateApplication(104)
    let ok = AXUIElementCreateApplication(105)
    let field = AXUIElementCreateApplication(106)
    var focused = list
    var enabled = true
    let targeting = WindowTargeting(attributeReader: { element, name in
      if CFEqual(element, app), name == kAXFocusedWindowAttribute { return sheet }
      if CFEqual(element, app), name == kAXFocusedUIElementAttribute { return focused }
      if CFEqual(element, sheet), name == kAXRoleAttribute { return kAXSheetRole as CFString }
      if CFEqual(element, sheet), name == kAXParentAttribute { return parent }
      if CFEqual(element, sheet), name == kAXChildrenAttribute { return [list, ok] as CFArray }
      if CFEqual(element, ok), name == kAXRoleAttribute { return kAXButtonRole as CFString }
      if CFEqual(element, ok), name == kAXIdentifierAttribute { return "OKButton" as CFString }
      if CFEqual(element, ok), name == kAXEnabledAttribute { return enabled as CFBoolean }
      if CFEqual(element, field), name == kAXRoleAttribute { return kAXTextFieldRole as CFString }
      return nil
    })
    XCTAssertTrue(targeting.remotePanelDefaultButton(parent, app: app).map { CFEqual($0, ok) } ?? false)
    enabled = false
    XCTAssertNil(targeting.remotePanelDefaultButton(parent, app: app))
    enabled = true
    focused = field
    XCTAssertNil(targeting.remotePanelDefaultButton(parent, app: app))
  }

  @MainActor
  func testLocalSheetsAndOrdinaryWindowsKeepTheAppProcess() {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let sheet = AXUIElementCreateApplication(103)
    let content = AXUIElementCreateApplication(104)
    for focused in [sheet, parent] {
      let targeting = WindowTargeting(attributeReader: { element, name in
        if CFEqual(element, app), name == kAXFocusedWindowAttribute { return focused }
        if CFEqual(element, sheet), name == kAXRoleAttribute { return kAXSheetRole as CFString }
        if CFEqual(element, sheet), name == kAXParentAttribute { return parent }
        if name == kAXChildrenAttribute, CFEqual(element, sheet) || CFEqual(element, parent) { return [content] as CFArray }
        return nil
      }, windowOwner: { element in
        // An ordinary window is never rerouted, even if a descendant reports another owner.
        CFEqual(element, content) && CFEqual(focused, parent) ? 950 : 900
      })
      XCTAssertEqual(targeting.keyboardProcess(parent, app: app, appPID: 900), 900)
    }
  }

  @MainActor
  func testNoKeyboardProcessWhenTheSelectedWindowLacksKeyboardFocus() {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let other = AXUIElementCreateApplication(103)
    let targeting = WindowTargeting(attributeReader: { element, name in
      if CFEqual(element, app), name == kAXFocusedWindowAttribute { return other }
      return nil
    }, windowOwner: { _ in 950 })
    XCTAssertNil(targeting.keyboardProcess(parent, app: app, appPID: 900))
  }

  @MainActor
  func testAttachedOpenPanelIsTheSelectedParentsKeyboardTargetWithoutFocusMutation() throws {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let sheet = AXUIElementCreateApplication(103)
    let targeting = WindowTargeting(attributeReader: { element, name in
      if CFEqual(element, app), name == kAXFocusedWindowAttribute { return sheet }
      if CFEqual(element, sheet), name == kAXRoleAttribute { return kAXSheetRole as CFString }
      if CFEqual(element, sheet), name == kAXParentAttribute { return parent }
      return nil
    }, focusRequester: { _ in XCTFail("An attached keyboard sheet must not refocus the blocked parent") },
      raiseRequester: { _ in XCTFail("Must not raise") })

    XCTAssertTrue(targeting.isKeyboardTarget(parent, app: app))
    try targeting.focus(parent, app: app)
    try targeting.requireTextTarget(parent, app: app)
  }

  @MainActor
  func testNestedGoToSheetIsAcceptedThroughItsOpenPanelParent() throws {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let panel = AXUIElementCreateApplication(103)
    let goTo = AXUIElementCreateApplication(104)
    let targeting = WindowTargeting(attributeReader: { element, name in
      if CFEqual(element, app), name == kAXFocusedWindowAttribute { return goTo }
      if CFEqual(element, goTo), name == kAXRoleAttribute { return kAXSheetRole as CFString }
      if CFEqual(element, goTo), name == kAXParentAttribute { return panel }
      if CFEqual(element, panel), name == kAXParentAttribute { return parent }
      return nil
    })
    XCTAssertTrue(targeting.isKeyboardTarget(parent, app: app))
    try targeting.requireTextTarget(parent, app: app)
  }

  @MainActor
  func testSheetOfAnotherWindowAndOrdinaryDescendantWindowAreRejected() {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let other = AXUIElementCreateApplication(103)
    let focused = AXUIElementCreateApplication(104)
    for (role, owner) in [(kAXSheetRole, other), (kAXWindowRole, parent)] {
      let targeting = WindowTargeting(attributeReader: { element, name in
        if CFEqual(element, app), name == kAXFocusedWindowAttribute { return focused }
        if CFEqual(element, focused), name == kAXRoleAttribute { return role as CFString }
        if CFEqual(element, focused), name == kAXParentAttribute { return owner }
        return nil
      })
      XCTAssertFalse(targeting.isKeyboardTarget(parent, app: app))
      XCTAssertThrowsError(try targeting.requireTextTarget(parent, app: app))
    }
  }

  @MainActor
  func testSheetWithoutVerifiedAttachmentDoesNotSubstituteForMissingFocus() {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let sheet = AXUIElementCreateApplication(103)
    for focused: AXUIElement? in [nil, sheet] {
      let targeting = WindowTargeting(attributeReader: { element, name in
        if CFEqual(element, app), name == kAXFocusedWindowAttribute { return focused }
        if CFEqual(element, parent), name == "AXSheets" { return [sheet] as CFArray }
        if CFEqual(element, sheet), name == kAXRoleAttribute { return kAXSheetRole as CFString }
        return nil
      })
      XCTAssertFalse(targeting.isKeyboardTarget(parent, app: app))
    }
  }

  @MainActor
  func testKeyboardTargetStopsMatchingWhenSheetMovesToAnotherParent() {
    let app = AXUIElementCreateApplication(101)
    let parent = AXUIElementCreateApplication(102)
    let other = AXUIElementCreateApplication(103)
    let sheet = AXUIElementCreateApplication(104)
    var owner = parent
    let targeting = WindowTargeting(attributeReader: { element, name in
      if CFEqual(element, app), name == kAXFocusedWindowAttribute { return sheet }
      if CFEqual(element, sheet), name == kAXRoleAttribute { return kAXSheetRole as CFString }
      if CFEqual(element, sheet), name == kAXParentAttribute { return owner }
      return nil
    })
    XCTAssertTrue(targeting.isKeyboardTarget(parent, app: app))
    owner = other
    XCTAssertFalse(targeting.isKeyboardTarget(parent, app: app))
  }

  @MainActor
  func testBackgroundFocusLeavesAnAlreadyFocusedEditableAlone() throws {
    let app = AXUIElementCreateApplication(101)
    let window = AXUIElementCreateApplication(102)
    let field = AXUIElementCreateApplication(103)
    let targeting = WindowTargeting(attributeReader: { element, name in
      guard CFEqual(element, app) else { return nil }
      return name == kAXFocusedWindowAttribute ? window : name == kAXFocusedUIElementAttribute ? field : nil
    }, focusRequester: { _ in XCTFail("Must not request window focus") },
      raiseRequester: { _ in XCTFail("Must not raise") },
      backgroundFocuser: { _, _ in XCTFail("Already focused editable must not be clicked") })
    try targeting.focusEditableInBackground(field, window: window, app: app)
  }

  @MainActor
  func testBackgroundFocusMovesFocusToTheFieldInAnotherWindowWithoutRaisingIt() throws {
    let app = AXUIElementCreateApplication(101)
    let window = AXUIElementCreateApplication(102)
    let field = AXUIElementCreateApplication(103)
    var focusedWindow = AXUIElementCreateApplication(104)
    var focusedField = AXUIElementCreateApplication(105)
    var requests: [(window: AXUIElement, field: AXUIElement)] = []
    let targeting = WindowTargeting(attributeReader: { element, name in
      guard CFEqual(element, app) else { return nil }
      return name == kAXFocusedWindowAttribute ? focusedWindow : name == kAXFocusedUIElementAttribute ? focusedField : nil
    }, focusRequester: { _ in XCTFail("Must not use AX window focus, which can activate the app") },
      raiseRequester: { _ in XCTFail("Must not raise") },
      backgroundFocuser: { requestedWindow, requestedField in
        requests.append((requestedWindow, requestedField))
        focusedWindow = requestedWindow
        focusedField = requestedField
      })

    try targeting.focusEditableInBackground(field, window: window, app: app)

    XCTAssertEqual(requests.count, 1)
    XCTAssertTrue(requests.first.map { CFEqual($0.window, window) && CFEqual($0.field, field) } ?? false)
  }

  @MainActor
  func testBackgroundFocusFailsWhenTheFieldDoesNotTakeFocus() {
    let app = AXUIElementCreateApplication(101)
    let window = AXUIElementCreateApplication(102)
    let field = AXUIElementCreateApplication(103)
    let decoy = AXUIElementCreateApplication(104)
    let targeting = WindowTargeting(attributeReader: { element, name in
      guard CFEqual(element, app) else { return nil }
      return name == kAXFocusedWindowAttribute ? window : name == kAXFocusedUIElementAttribute ? decoy : nil
    }, backgroundFocuser: { _, _ in }, focusPollInterval: 0)
    XCTAssertThrowsError(try targeting.focusEditableInBackground(field, window: window, app: app)) { error in
      XCTAssertEqual((error as? PilotRuntimeError)?.code, "element_focus_failed")
    }
  }

  @MainActor
  func testBackgroundFocusDoesNotUnminimizeTheWindow() {
    let app = AXUIElementCreateApplication(101)
    let window = AXUIElementCreateApplication(102)
    let field = AXUIElementCreateApplication(103)
    let targeting = WindowTargeting(attributeReader: { element, name in
      CFEqual(element, window) && name == kAXMinimizedAttribute ? kCFBooleanTrue : nil
    }, backgroundFocuser: { _, _ in XCTFail("Minimized windows must not be clicked") })
    XCTAssertThrowsError(try targeting.focusEditableInBackground(field, window: window, app: app)) { error in
      XCTAssertEqual((error as? PilotRuntimeError)?.code, "window_focus_failed")
    }
  }

  @MainActor
  func testBackgroundTextRefusesOtherWindowWithoutSelectingOrRaisingIt() {
    let app = AXUIElementCreateApplication(101)
    let window = AXUIElementCreateApplication(102)
    let other = AXUIElementCreateApplication(103)
    var selections = 0
    var raises = 0
    let targeting = WindowTargeting(attributeReader: { _, name in
      name == kAXFocusedWindowAttribute ? other : nil
    }, focusRequester: { _ in selections += 1 }, raiseRequester: { _ in raises += 1 })

    XCTAssertThrowsError(try targeting.requireTextTarget(window, app: app)) { error in
      XCTAssertEqual((error as? PilotRuntimeError)?.code, "window_focus_failed")
    }
    XCTAssertEqual(selections, 0)
    XCTAssertEqual(raises, 0)
  }

  @MainActor
  func testBackgroundTextAcceptsAlreadySelectedWindowWithoutFocusMutation() throws {
    let app = AXUIElementCreateApplication(101)
    let window = AXUIElementCreateApplication(102)
    let targeting = WindowTargeting(attributeReader: { _, name in
      name == kAXFocusedWindowAttribute ? window : nil
    }, focusRequester: { _ in XCTFail("No selection") }, raiseRequester: { _ in XCTFail("No raising") })
    try targeting.requireTextTarget(window, app: app)
  }

  @MainActor
  func testBackgroundTextDoesNotUnminimizeTheWindow() {
    let app = AXUIElementCreateApplication(101)
    let window = AXUIElementCreateApplication(102)
    let targeting = WindowTargeting(attributeReader: { _, name in
      if name == kAXFocusedWindowAttribute { return window }
      if name == kAXMinimizedAttribute { return kCFBooleanTrue }
      return nil
    }, focusRequester: { _ in XCTFail("No selection") }, raiseRequester: { _ in XCTFail("No raising") })
    XCTAssertThrowsError(try targeting.requireTextTarget(window, app: app))
  }

  @MainActor
  func testBackgroundKeyboardSelectionDoesNotRaiseWindow() throws {
    let app = AXUIElementCreateApplication(101)
    let window = AXUIElementCreateApplication(102)
    var focused = app
    var raises = 0
    let targeting = WindowTargeting(attributeReader: { _, name in
      name == kAXFocusedWindowAttribute ? focused : nil
    }, focusRequester: { focused = $0 }, raiseRequester: { _ in raises += 1 })
    try targeting.focus(window, app: app)
    XCTAssertEqual(raises, 0)
    focused = app
    try targeting.focus(window, app: app, allowRaise: true)
    XCTAssertEqual(raises, 1)
  }

  @MainActor
  func testKeyboardFocusSelectsExactWindowAndVerifiesIt() throws {
    let first = AXUIElementCreateApplication(101)
    let second = AXUIElementCreateApplication(102)
    var focused = first
    var requests = 0
    let targeting = WindowTargeting(attributeReader: { _, name in
      name == kAXFocusedWindowAttribute ? focused : nil
    }, focusRequester: { window in
      requests += 1
      focused = window
    })
    try targeting.focus(first, app: first)
    XCTAssertEqual(requests, 0)
    try targeting.focus(second, app: first)
    XCTAssertEqual(requests, 1)
    XCTAssertTrue(targeting.isKeyboardTarget(second, app: first))
  }

  @MainActor
  func testKeyboardFocusFailsWhenAppKeepsAnotherWindowSelected() {
    let first = AXUIElementCreateApplication(101)
    let second = AXUIElementCreateApplication(102)
    let targeting = WindowTargeting(attributeReader: { _, name in
      name == kAXFocusedWindowAttribute ? first : nil
    }, focusRequester: { _ in })
    XCTAssertThrowsError(try targeting.focus(second, app: first)) { error in
      XCTAssertEqual((error as? PilotRuntimeError)?.code, "window_focus_failed")
    }
  }

  @MainActor
  func testElementOwnershipRejectsAnotherWindow() {
    let first = AXUIElementCreateApplication(101)
    let second = AXUIElementCreateApplication(102)
    let child = AXUIElementCreateApplication(103)
    let targeting = WindowTargeting(attributeReader: { element, name in
      if CFEqual(element, child) && name == kAXWindowAttribute { return second }
      return nil
    })
    XCTAssertTrue(targeting.contains(child, window: second))
    XCTAssertFalse(targeting.contains(child, window: first))
  }

  func testWindowIDSurvivesReordering() throws {
    let selection = WindowSelection<String>(equal: ==)
    let id = selection.id(for: "b", pid: 1)
    let first = try selection.resolve(pid: 1, requested: id, windows: ["a", "b"])
    let next = try selection.resolve(pid: 1, requested: id, windows: ["b", "a"])
    XCTAssertEqual(first.id, next.id)
    XCTAssertEqual(next.element, "b")
  }

  func testListingPreservesIDsAndEveryResolutionUsesItsExplicitID() throws {
    let selection = WindowSelection<String>(equal: ==)
    let firstID = selection.id(for: "a", pid: 1)
    let otherID = selection.id(for: "b", pid: 1)
    XCTAssertEqual(selection.id(for: "a", pid: 1), firstID)
    XCTAssertEqual(try selection.resolve(pid: 1, requested: firstID, windows: ["a", "b"]).element, "a")
    XCTAssertEqual(try selection.resolve(pid: 1, requested: otherID, windows: ["a", "b"]).element, "b")
  }

  func testClosedSelectionNeverFallsBackAndCanBeReplacedExplicitly() throws {
    let selection = WindowSelection<String>(equal: ==)
    let oldID = selection.id(for: "a", pid: 1)
    XCTAssertThrowsError(try selection.resolve(pid: 1, requested: oldID, windows: ["b"]))
    let newID = selection.id(for: "b", pid: 1)
    XCTAssertEqual(try selection.resolve(pid: 1, requested: newID, windows: ["b"]).element, "b")
  }

  func testIDsAreAppBoundAndUnknownIDsDoNotFallback() throws {
    let selection = WindowSelection<String>(equal: ==)
    let id = selection.id(for: "a", pid: 1)
    XCTAssertThrowsError(try selection.resolve(pid: 2, requested: id, windows: ["a"]))
    XCTAssertThrowsError(try selection.resolve(pid: 1, requested: 999, windows: ["a"]))
    XCTAssertThrowsError(try selection.resolve(pid: 1, requested: id, windows: []))
  }

  func testWindowCaptureRequiresBothTitleAndGeometry() {
    let bounds = CGRect(x: -1700, y: 40, width: 1600, height: 900)
    let target = WindowCaptureTarget(windowID: 1, title: "Example", bounds: bounds)
    XCTAssertTrue(target.matches(title: "Example", bounds: bounds))
    XCTAssertFalse(target.matches(title: "GitHub", bounds: bounds))
    XCTAssertFalse(target.matches(title: "Example", bounds: bounds.offsetBy(dx: 1700, dy: 0)))
    XCTAssertTrue(target.matches(title: "Example", bounds: bounds.offsetBy(dx: 0.5, dy: 0)))
  }
}
