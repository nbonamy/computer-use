import Darwin
import Foundation

enum TargetBoundKeyboardInputError: Error, Equatable {
  case targetLostFocus
}

struct TargetBoundKeyboardInput {
  let isTargetFocused: (pid_t) -> Bool
  let pauseBetweenCharacters: () -> Void
  let postCharacter: (Character) -> Void

  func post(_ text: String, targetPID: pid_t) throws {
    for character in text {
      guard isTargetFocused(targetPID) else {
        throw TargetBoundKeyboardInputError.targetLostFocus
      }
      postCharacter(character)
      pauseBetweenCharacters()
    }
  }
}
