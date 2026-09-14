import CoreGraphics
import Foundation

struct KeyboardChord: Equatable, Sendable {
  let flags: CGEventFlags
  let keyCode: CGKeyCode?
  let text: String?

  static func parse(_ value: String) throws -> KeyboardChord {
    let parts = value.split(separator: "+", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }), let key = parts.last else {
      throw PilotRuntimeError(code: "invalid_request", message: "key must be a key name or a + separated chord.")
    }

    var flags: CGEventFlags = []
    for modifier in parts.dropLast() {
      switch modifier.lowercased() {
      case "control", "ctrl", "control_l", "control_r": flags.insert(.maskControl)
      case "shift", "shift_l", "shift_r": flags.insert(.maskShift)
      case "alt", "option", "alt_l", "alt_r", "option_l", "option_r": flags.insert(.maskAlternate)
      case "super", "command", "cmd", "meta", "super_l", "super_r": flags.insert(.maskCommand)
      default:
        throw PilotRuntimeError(code: "invalid_request", message: "Unknown key modifier \(modifier).")
      }
    }

    if key.count == 1 {
      if flags.isEmpty {
        return KeyboardChord(flags: flags, keyCode: nil, text: key)
      }
      guard let keyCode = keyCodes[key.lowercased()] else {
        throw PilotRuntimeError(code: "invalid_request", message: "The modified key \(key) is not supported.")
      }
      return KeyboardChord(flags: flags, keyCode: keyCode, text: nil)
    }
    if let keyCode = keyCodes[key.lowercased()] {
      return KeyboardChord(flags: flags, keyCode: keyCode, text: nil)
    }
    throw PilotRuntimeError(code: "invalid_request", message: "Unknown key name \(key).")
  }
}

private let keyCodes: [String: CGKeyCode] = [
  "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
  "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
  "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
  "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
  "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
  ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "tab": 48, "space": 49, "`": 50,
  "backspace": 51, "delete": 51, "escape": 53, "esc": 53,
  "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
  "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
  "home": 115, "end": 119, "page_up": 116, "pageup": 116, "page_down": 121, "pagedown": 121,
  "left": 123, "right": 124, "down": 125, "up": 126, "forward_delete": 117
]
