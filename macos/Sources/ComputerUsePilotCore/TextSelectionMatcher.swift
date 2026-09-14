import Foundation

enum TextSelectionMatcher {
  static func uniqueRange(in value: String, text: String, prefix: String?, suffix: String?) throws -> NSRange {
    let source = value as NSString
    let needleLength = (text as NSString).length
    var searchRange = NSRange(location: 0, length: source.length)
    var matches: [NSRange] = []

    while searchRange.length > 0 {
      let found = source.range(of: text, options: [], range: searchRange)
      if found.location == NSNotFound { break }
      let prefixMatches = prefix.map { expected in
        let length = (expected as NSString).length
        return found.location >= length
          && source.substring(with: NSRange(location: found.location - length, length: length)) == expected
      } ?? true
      let suffixMatches = suffix.map { expected in
        let length = (expected as NSString).length
        let location = found.location + found.length
        return location + length <= source.length
          && source.substring(with: NSRange(location: location, length: length)) == expected
      } ?? true
      if prefixMatches && suffixMatches { matches.append(found) }
      let next = found.location + max(needleLength, 1)
      searchRange = NSRange(location: next, length: source.length - next)
    }

    guard matches.count == 1, let match = matches.first else {
      throw PilotRuntimeError(
        code: matches.isEmpty ? "element_not_found" : "ambiguous_target",
        message: matches.isEmpty
          ? "The requested text was not found in the element."
          : "The requested text matched multiple ranges; provide prefix or suffix."
      )
    }
    return match
  }
}
