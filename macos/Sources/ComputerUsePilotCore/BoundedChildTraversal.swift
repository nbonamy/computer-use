func boundedChildNodes<Element>(
  _ children: [Element],
  remaining: inout Int?,
  makeNode: (Element, Int, inout Int?) -> JSONValue
) -> [JSONValue] {
  var nodes: [JSONValue] = []
  for (index, child) in children.enumerated() {
    if let remaining, remaining <= 0 {
      nodes.append(.object(["truncated": .bool(true)]))
      break
    }
    nodes.append(makeNode(child, index, &remaining))
  }
  return nodes
}
