import ApplicationServices
import XCTest
@testable import ComputerUsePilotCore

final class PopUpOptionsTests: XCTestCase {
  /// A label that wraps its <select> must be clicked beside the control, never
  /// on it: a click on the control opens the menu.
  func testLabelClickPointAvoidsAWrappedControl() {
    let control = CGRect(x: 100, y: 50, width: 120, height: 20)
    XCTAssertEqual(PopUpOptions.labelClickPoint(label: CGRect(x: 40, y: 48, width: 180, height: 24), control: control),
      CGPoint(x: 70, y: 60))
    XCTAssertEqual(PopUpOptions.labelClickPoint(label: CGRect(x: 100, y: 48, width: 160, height: 24), control: control),
      CGPoint(x: 240, y: 60))
    XCTAssertNil(PopUpOptions.labelClickPoint(label: CGRect(x: 99, y: 48, width: 122, height: 24), control: control))
    let separate = CGRect(x: 10, y: 20, width: 80, height: 16)
    XCTAssertEqual(PopUpOptions.labelClickPoint(label: separate, control: control), CGPoint(x: 50, y: 28))
  }

  func testOptionsAreAppendedToTheDropdownLine() {
    XCTAssertEqual(PopUpOptions.line(#"120 pop up button "Preferred Resolution" value="Refund""#, options: ["Refund", "Other"]),
      #"120 pop up button "Preferred Resolution" value="Refund" options=Refund|Other"#)
  }

  /// AppKit pop-ups own their menu; WebKit adds a new menu elsewhere in the
  /// page while a <select> is open. Either way, only menu items are options.
  @MainActor
  func testOpenedMenuIsTheButtonsOwnOrTheOneThatAppeared() {
    let own = AXUIElementCreateApplication(2)
    let existing = AXUIElementCreateApplication(3)
    let appeared = AXUIElementCreateApplication(4)
    XCTAssertTrue(PopUpOptions.openedMenu(ownMenus: [own], before: [existing], after: [existing, appeared])
      .map { CFEqual($0, own) } ?? false)
    XCTAssertTrue(PopUpOptions.openedMenu(ownMenus: [], before: [existing], after: [existing, appeared])
      .map { CFEqual($0, appeared) } ?? false)
    XCTAssertNil(PopUpOptions.openedMenu(ownMenus: [], before: [existing], after: [existing]))
  }

  /// Opening a background app's menu orders its window group above the
  /// user's window without activating it; the user's window is raised back
  /// only when it was on top before.
  func testUserWindowIsRaisedBackOnlyWhenSomethingCoveredIt() {
    XCTAssertTrue(SyntheticAppFocus.FrontSnapshot.windowCovered(window: 7, wasOnTop: true, order: [42, 7, 9]))
    XCTAssertFalse(SyntheticAppFocus.FrontSnapshot.windowCovered(window: 7, wasOnTop: true, order: [7, 42]))
    XCTAssertFalse(SyntheticAppFocus.FrontSnapshot.windowCovered(window: 7, wasOnTop: false, order: [42, 7]))
  }

  func testOptionMatchingIgnoresCaseAndSurroundingSpace() {
    XCTAssertEqual(PopUpOptions.matchingIndex(of: " replacement ", in: ["Refund", "Replacement", "Other"]), 1)
    XCTAssertNil(PopUpOptions.matchingIndex(of: "Atlantis", in: ["Refund", "Other"]))
  }
}
