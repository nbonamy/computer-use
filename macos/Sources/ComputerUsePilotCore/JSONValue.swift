import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
  case array([JSONValue])
  case bool(Bool)
  case null
  case number(Double)
  case object([String: JSONValue])
  case string(String)

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .array(let value):
      try container.encode(value)
    case .bool(let value):
      try container.encode(value)
    case .null:
      try container.encodeNil()
    case .number(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    }
  }

  public var objectValue: [String: JSONValue]? {
    if case .object(let value) = self {
      return value
    }
    return nil
  }

  public var stringValue: String? {
    if case .string(let value) = self {
      return value
    }
    return nil
  }

  public var intValue: Int? {
    if case .number(let value) = self {
      return Int(value)
    }
    return nil
  }

  public var numberValue: Double? {
    if case .number(let value) = self {
      return value
    }
    return nil
  }

  public var boolValue: Bool? {
    if case .bool(let value) = self {
      return value
    }
    return nil
  }
}

public extension JSONValue {
  static func from(_ value: Any?) -> JSONValue {
    switch value {
    case nil:
      return .null
    case let value as String:
      return .string(value)
    case let value as Bool:
      return .bool(value)
    case let value as Int:
      return .number(Double(value))
    case let value as Double:
      return .number(value)
    case let value as CGFloat:
      return .number(Double(value))
    case let value as [String: JSONValue]:
      return .object(value)
    case let value as [JSONValue]:
      return .array(value)
    default:
      return .string(String(describing: value!))
    }
  }
}
