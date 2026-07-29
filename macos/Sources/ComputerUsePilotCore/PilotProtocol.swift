@preconcurrency import Foundation
import Darwin

public struct PilotRequest: Codable, Equatable, Sendable {
  public let arguments: [String: JSONValue]
  public let command: String
  public let id: String?

  public init(id: String?, command: String, arguments: [String: JSONValue] = [:]) {
    self.arguments = arguments
    self.command = command
    self.id = id
  }

  enum CodingKeys: String, CodingKey {
    case arguments
    case command
    case id
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.arguments = try container.decodeIfPresent([String: JSONValue].self, forKey: .arguments) ?? [:]
    self.command = try container.decode(String.self, forKey: .command)
    self.id = try container.decodeIfPresent(String.self, forKey: .id)
  }
}

public struct PilotError: Codable, Equatable, Sendable {
  public let code: String
  public let message: String

  public init(code: String, message: String) {
    self.code = code
    self.message = message
  }
}

public struct PilotResponse: Codable, Equatable, Sendable {
  public let error: PilotError?
  public let id: String?
  public let ok: Bool
  public let result: JSONValue?

  public static func success(id: String?, result: JSONValue) -> PilotResponse {
    PilotResponse(error: nil, id: id, ok: true, result: result)
  }

  public static func failure(id: String?, code: String, message: String) -> PilotResponse {
    PilotResponse(error: PilotError(code: code, message: message), id: id, ok: false, result: nil)
  }
}

public final class StdioPilotRunner: @unchecked Sendable {
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()
  private let handlerBox: PilotHandlerBox
  private let runHandlerOnMainThread: Bool

  public init(handler: @escaping @MainActor @Sendable (PilotRequest) -> PilotResponse, runHandlerOnMainThread: Bool = false) {
    self.handlerBox = PilotHandlerBox(handler)
    self.runHandlerOnMainThread = runHandlerOnMainThread
    self.encoder.outputFormatting = [.sortedKeys]
  }

  public func handleLine(_ line: String) -> String {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return encode(PilotResponse.failure(id: nil, code: "invalid_request", message: "Request line is empty."))
    }

    do {
      guard let data = trimmed.data(using: .utf8) else {
        return encode(PilotResponse.failure(id: nil, code: "invalid_request", message: "Request is not valid UTF-8."))
      }
      let request = try decoder.decode(PilotRequest.self, from: data)
      return encode(invokeHandler(request))
    } catch {
      return encode(PilotResponse.failure(id: nil, code: "invalid_request", message: error.localizedDescription))
    }
  }

  private func invokeHandler(_ request: PilotRequest) -> PilotResponse {
    let box = handlerBox
    guard runHandlerOnMainThread else {
      return MainActor.assumeIsolated { box.handler(request) }
    }
    if Thread.isMainThread {
      return MainActor.assumeIsolated { box.handler(request) }
    }
    return DispatchQueue.main.sync { @MainActor in box.handler(request) }
  }

  public func run() {
    while let line = readLine(strippingNewline: true) {
      print(handleLine(line))
      fflush(stdout)
    }
    if runHandlerOnMainThread {
      DispatchQueue.main.async {
        exit(EXIT_SUCCESS)
      }
    }
  }

  private func encode(_ response: PilotResponse) -> String {
    do {
      let data = try encoder.encode(response)
      return String(data: data, encoding: .utf8) ?? #"{"ok":false,"error":{"code":"encode_error","message":"Response was not valid UTF-8"}}"#
    } catch {
      return #"{"ok":false,"error":{"code":"encode_error","message":"Unable to encode response"}}"#
    }
  }
}

private final class PilotHandlerBox: @unchecked Sendable {
  let handler: @MainActor @Sendable (PilotRequest) -> PilotResponse

  init(_ handler: @escaping @MainActor @Sendable (PilotRequest) -> PilotResponse) {
    self.handler = handler
  }
}
