import Foundation

struct AccessibilityStateRow: Equatable, Sendable {
  let elementIndex: Int
  let line: String
  let parentElementIndex: Int?
  let siblingIndex: Int
}

struct AccessibilityStateRender: Equatable, Sendable {
  let baseRevision: Int?
  let fullText: String
  let kind: String
  let revision: Int
  let text: String
}

@MainActor
final class AccessibilityStateHistory {
  private struct Baseline {
    let revision: Int
    let rows: [AccessibilityStateRow]
  }

  private var baselines: [String: Baseline] = [:]
  private var nextRevision = 1

  func render(
    key: String,
    header: [String],
    rows: [AccessibilityStateRow],
    footer: [String],
    disableDiff: Bool,
    maxTextCharacters: Int? = nil
  ) -> AccessibilityStateRender {
    let revision = nextRevision
    nextRevision += 1
    let fullText = (header + rows.map(\.line) + footer).joined(separator: "\n")
    let previous = baselines[key]

    // A caller that did not receive a complete baseline cannot interpret a
    // later diff safely. Keep returning full states until the chosen budget can
    // hold one complete hierarchy.
    if let maxTextCharacters, fullText.count > maxTextCharacters {
      baselines.removeValue(forKey: key)
      return AccessibilityStateRender(
        baseRevision: nil,
        fullText: fullText,
        kind: "full",
        revision: revision,
        text: fullText
      )
    }
    baselines[key] = Baseline(revision: revision, rows: rows)

    guard !disableDiff, let previous else {
      return AccessibilityStateRender(
        baseRevision: nil,
        fullText: fullText,
        kind: "full",
        revision: revision,
        text: fullText
      )
    }

    let oldByID = previous.rows.reduce(into: [Int: AccessibilityStateRow]()) { result, row in
      result[row.elementIndex] = row
    }
    let newByID = rows.reduce(into: [Int: AccessibilityStateRow]()) { result, row in
      result[row.elementIndex] = row
    }
    var changes: [String] = []

    var removedIDs: Set<Int> = []
    for row in previous.rows where newByID[row.elementIndex] == nil && removedIDs.insert(row.elementIndex).inserted {
      changes.append("- \(row.line)")
    }
    var emittedCurrentIDs: Set<Int> = []
    for row in rows {
      guard emittedCurrentIDs.insert(row.elementIndex).inserted else { continue }
      guard let old = oldByID[row.elementIndex] else {
        changes.append("+ \(row.line)")
        continue
      }
      if old.line != row.line
        || old.parentElementIndex != row.parentElementIndex
        || old.siblingIndex != row.siblingIndex {
        changes.append("~ \(row.line)")
      }
    }

    let diffHeader = [
      "Computer Use Accessibility diff revision \(revision) from \(previous.revision)",
      "Prefixes: + added, ~ changed or moved, - removed. Unprefixed elements remain unchanged."
    ]
    let diffText = (diffHeader + (changes.isEmpty ? ["(no accessibility changes)"] : changes) + footer)
      .joined(separator: "\n")

    return AccessibilityStateRender(
      baseRevision: previous.revision,
      fullText: fullText,
      kind: "diff",
      revision: revision,
      text: diffText
    )
  }

  func reset() {
    baselines.removeAll()
  }
}
