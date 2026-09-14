import Foundation

/// Bounded stability detection; quiet AX state is evidence, not proof of application success.
struct ObservationSettler {
  static func isLoading(role: String?, busy: Bool, loaded: Bool?, progress: Double?) -> Bool {
    busy || (role == "AXWebArea" && (loaded == false || progress.map { $0 < 1 } == true))
  }
  var previous: String?
  var stableSince: TimeInterval = 0
  var matchedSince: TimeInterval?

  mutating func ready(signature: String, busy: Bool, elapsed: TimeInterval, expected: String?) -> Bool {
    if signature != previous || busy { stableSince = elapsed }
    previous = signature
    if let expected {
      guard !busy && signature.contains(expected) else { matchedSince = nil; return false }
      if matchedSince == nil { matchedSince = elapsed }
      return elapsed - (matchedSince ?? elapsed) >= 0.3
    }
    return !busy && elapsed >= 0.8 && elapsed - stableSince >= 0.4
  }
}
