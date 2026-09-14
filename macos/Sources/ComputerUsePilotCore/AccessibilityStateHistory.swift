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

    let removedIDs = Set(previous.rows.filter { newByID[$0.elementIndex] == nil }.map(\.elementIndex)).sorted()
    if !removedIDs.isEmpty { changes.append("Removed IDs: \(compactIDRanges(removedIDs))") }
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
      "Prefixes: + added, ~ changed or moved. Removed IDs are no longer actionable."
    ]
    let diffText = (diffHeader + (changes.isEmpty ? ["(no accessibility changes)"] : changes) + footer)
      .joined(separator: "\n")

    if !changes.isEmpty && diffText.count > fullText.count {
      return AccessibilityStateRender(baseRevision: nil, fullText: fullText, kind: "full", revision: revision, text: fullText)
    }

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

  private func compactIDRanges(_ ids: [Int]) -> String {
    var ranges: [String] = []
    var start = ids[0]
    var end = start
    for id in ids.dropFirst() {
      if id == end + 1 { end = id; continue }
      ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
      start = id
      end = id
    }
    ranges.append(start == end ? "\(start)" : "\(start)-\(end)")
    return ranges.joined(separator: ", ")
  }
}
