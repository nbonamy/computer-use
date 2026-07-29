import AppKit
import Foundation
import ComputerUsePilotCore

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let pilot = AccessibilityPilot()
let runner = StdioPilotRunner(handler: pilot.handle, runHandlerOnMainThread: true)

DispatchQueue.global(qos: .userInitiated).async {
  runner.run()
}
RunLoop.main.run()
