import AppKit
import Foundation
import ComputerUsePilotCore

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let pilot = AccessibilityPilot()
let runner = StdioPilotRunner(handler: pilot.handle, runHandlerOnMainThread: true)

// The helper ends on stdin EOF (exit) or SIGTERM; both restore target apps.
atexit {
  MainActor.assumeIsolated { pilot.shutdown() }
}
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler { exit(EXIT_SUCCESS) }
termination.resume()

DispatchQueue.global(qos: .userInitiated).async {
  runner.run()
}
RunLoop.main.run()
