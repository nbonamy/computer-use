import Foundation

enum PilotArguments {
  static func validate(command: String, arguments: [String: JSONValue]) throws {
    let target: Set<String> = ["app", "pid", "path", "bundleIdentifier", "window_id", "accessibilityScope", "showCursor"]
    let indexed: Set<String> = ["element_index", "elementIndex", "selector", "maxDepth"]
    let commands: [String: Set<String>] = [
      "ping": [], "status": [], "list_apps": [], "list_windows": [],
      "request_accessibility": ["prompt", "openSettings"], "request_screen_capture": [],
      "find_apps": ["query", "maxResults"], "launch_app": ["activate"], "focus_app": [],
      "get_app_state": ["rootElementIndex", "maxDepth", "maxNodes", "maxTextCharacters", "includeElements", "includeTree", "includeDebug", "includeScreenshot", "includeContextSnapshot", "disableDiff", "waitForText", "timeoutMs"],
      "screenshot": ["scope", "displayId"],
      "click": indexed.union(["x", "y", "click_count", "mouse_button", "physical"]),
      "dismiss": indexed, "set_value": indexed.union(["value", "text"]),
      "type_text": indexed.union(["text", "replace", "submit"]),
      "press_key": ["key"], "paste": ["text", "format"],
      "scroll": indexed.union(["direction", "pages"]),
      "drag": ["from_x", "from_y", "to_x", "to_y"],
      "perform_secondary_action": indexed.union(["action"]),
      "select_text": indexed.union(["text", "prefix", "suffix", "selection_type"])
    ]
    guard let allowed = commands[command] else { return }
    let unknown = Set(arguments.keys).subtracting(target.union(allowed)).sorted()
    guard unknown.isEmpty else {
      throw PilotRuntimeError(code: "invalid_request", message: "Unknown arguments for \(command): \(unknown.joined(separator: ", ")).")
    }
    for key in ["replace", "submit", "physical", "includeScreenshot", "disableDiff"] {
      if let value = arguments[key], value.boolValue == nil {
        throw PilotRuntimeError(code: "invalid_request", message: "\(key) must be a boolean.")
      }
    }
    if let value = arguments["waitForText"], value.stringValue?.isEmpty != false {
      throw PilotRuntimeError(code: "invalid_request", message: "waitForText must be a nonempty string.")
    }
    if let value = arguments["timeoutMs"], value.intValue.map({ (1...15_000).contains($0) }) != true {
      throw PilotRuntimeError(code: "invalid_request", message: "timeoutMs must be an integer from 1 to 15000.")
    }
  }
}
