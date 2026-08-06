import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
protocol ScreenCapturing {
  var isTrusted: Bool { get }

  func requestAccess() -> Bool
  func captureScreen(displayID: CGDirectDisplayID?) throws -> JSONValue
  func captureWindow(application: NSRunningApplication) throws -> JSONValue
}

@MainActor
final class MacScreenCapturer: ScreenCapturing {
  var isTrusted: Bool {
    CGPreflightScreenCaptureAccess()
  }

  func requestAccess() -> Bool {
    CGRequestScreenCaptureAccess()
  }

  func captureScreen(displayID requestedDisplayID: CGDirectDisplayID?) throws -> JSONValue {
    try requireAccess()
    let displayID = requestedDisplayID ?? CGMainDisplayID()
    let content = try shareableContent()
    guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
      throw PilotRuntimeError(code: "screen_not_found", message: "Could not find active display \(displayID).")
    }
    let filter = SCContentFilter(display: display, excludingWindows: [])
    let image = try captureImage(filter: filter)
    let bounds = display.frame
    return .object([
      "image": try imageDescription(image, logicalWidth: bounds.width),
      "scope": .string("screen"),
      "screen": .object([
        "bounds": rectDescription(bounds),
        "id": .number(Double(displayID)),
        "isMain": .bool(displayID == CGMainDisplayID())
      ]),
      "success": .bool(true)
    ])
  }

  func captureWindow(application: NSRunningApplication) throws -> JSONValue {
    try requireAccess()
    let content = try shareableContent()
    guard let window = content.windows.first(where: {
      $0.owningApplication?.processID == application.processIdentifier
        && $0.windowLayer == 0
        && $0.isOnScreen
    }) else {
      throw PilotRuntimeError(code: "window_not_found", message: "Could not find a visible window for the target app.")
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let image = try captureImage(filter: filter)
    let bounds = window.frame

    return .object([
      "app": runningApplicationDescription(application),
      "image": try imageDescription(image, logicalWidth: bounds.width),
      "scope": .string("window"),
      "success": .bool(true),
      "window": .object([
        "bounds": rectDescription(bounds),
        "id": .number(Double(window.windowID)),
        "title": .from(window.title)
      ])
    ])
  }

  private func requireAccess() throws {
    guard isTrusted else {
      throw PilotRuntimeError(
        code: "screen_capture_not_granted",
        message: "Computer Use does not have macOS Screen Recording permission."
      )
    }
  }

  private func shareableContent() throws -> SCShareableContent {
    let result = CallbackResultBox<SCShareableContent>()
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
      result.complete(value: content, error: error)
    }
    do {
      return try result.wait()
    } catch {
      throw PilotRuntimeError(code: "screen_capture_failed", message: error.localizedDescription)
    }
  }

  private func captureImage(filter: SCContentFilter) throws -> CGImage {
    let configuration = SCStreamConfiguration()
    let scale = max(CGFloat(filter.pointPixelScale), 1)
    configuration.width = max(Int(filter.contentRect.width * scale), 1)
    configuration.height = max(Int(filter.contentRect.height * scale), 1)
    configuration.showsCursor = false
    configuration.ignoreShadowsSingleWindow = true
    let result = CallbackResultBox<CGImage>()
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
      result.complete(value: image, error: error)
    }
    do {
      return try result.wait()
    } catch {
      throw PilotRuntimeError(code: "screen_capture_failed", message: error.localizedDescription)
    }
  }

  private func imageDescription(_ image: CGImage, logicalWidth: CGFloat) throws -> JSONValue {
    let representation = NSBitmapImageRep(cgImage: image)
    guard let png = representation.representation(using: .png, properties: [:]) else {
      throw PilotRuntimeError(code: "screen_capture_failed", message: "Could not encode the screenshot.")
    }
    let scaleFactor = logicalWidth > 0 ? Double(image.width) / Double(logicalWidth) : 1
    return .object([
      "dataBase64": .string(png.base64EncodedString()),
      "height": .number(Double(image.height)),
      "mimeType": .string("image/png"),
      "scaleFactor": .number(scaleFactor),
      "width": .number(Double(image.width))
    ])
  }

  private func rectDescription(_ rect: CGRect) -> JSONValue {
    .object([
      "height": .number(Double(rect.height)),
      "width": .number(Double(rect.width)),
      "x": .number(Double(rect.origin.x)),
      "y": .number(Double(rect.origin.y))
    ])
  }

  private func runningApplicationDescription(_ app: NSRunningApplication) -> JSONValue {
    .object([
      "active": .bool(app.isActive),
      "bundleIdentifier": .from(app.bundleIdentifier),
      "localizedName": .from(app.localizedName),
      "path": .from(app.bundleURL?.path),
      "pid": .number(Double(app.processIdentifier)),
      "terminated": .bool(app.isTerminated)
    ])
  }
}

private final class CallbackResultBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var error: Error?
  private var value: Value?

  func complete(value: Value?, error: Error?) {
    lock.lock()
    self.value = value
    self.error = error
    lock.unlock()
    semaphore.signal()
  }

  func wait() throws -> Value {
    semaphore.wait()
    lock.lock()
    defer { lock.unlock() }
    if let error {
      throw error
    }
    guard let value else {
      throw PilotRuntimeError(code: "screen_capture_failed", message: "ScreenCaptureKit returned no image.")
    }
    return value
  }
}
