import Foundation

/// An SSH destination and an explicit remote socket, so remote Docker contexts cannot
/// redirect a later removal to another daemon.
public struct DockerSSHHost: Hashable, Sendable {
  public static let scheme = "ssh"
  public static let defaultSocketPath = "/var/run/docker.sock"

  public let host: String
  public let user: String?
  public let port: UInt16?
  public let socketPath: String

  /// Accepts `ssh://user@server:2222`, an SSH config alias, and an optional socket path.
  public init(_ value: String) throws {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    let address = trimmed.contains("://") ? trimmed : "\(Self.scheme)://\(trimmed)"
    guard !trimmed.isEmpty,
      let components = URLComponents(string: address),
      components.scheme?.lowercased() == Self.scheme,
      let rawHost = components.host, !rawHost.isEmpty,
      components.password == nil, components.query == nil, components.fragment == nil
    else { throw DockerSSHHostError.invalidAddress }

    let host =
      rawHost.hasPrefix("[") && rawHost.hasSuffix("]")
      ? String(rawHost.dropFirst().dropLast()) : rawHost
    let nameCharacters = CharacterSet(
      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    let hostCharacters =
      host.contains(":")
      ? CharacterSet(charactersIn: "abcdefABCDEF0123456789:.") : nameCharacters
    guard !host.hasPrefix("-"), host.unicodeScalars.allSatisfy(hostCharacters.contains),
      components.user.map({
        !$0.isEmpty && !$0.hasPrefix("-") && $0.unicodeScalars.allSatisfy(nameCharacters.contains)
      }) ?? true
    else { throw DockerSSHHostError.invalidAddress }

    let port: UInt16?
    if let number = components.port {
      guard let validated = UInt16(exactly: number), validated > 0 else {
        throw DockerSSHHostError.invalidAddress
      }
      port = validated
    } else {
      // URLComponents treats a trailing colon as an absent port.
      let authority = address.dropFirst("\(Self.scheme)://".count).prefix { $0 != "/" }
      guard !authority.hasSuffix(":") else {
        throw DockerSSHHostError.invalidAddress
      }
      port = nil
    }

    let path = components.path
    let socketPath = path.isEmpty || path == "/" ? Self.defaultSocketPath : path
    guard socketPath.hasPrefix("/"),
      socketPath.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F })
    else { throw DockerSSHHostError.invalidAddress }

    self.host = host
    self.user = components.user
    self.port = port
    self.socketPath = socketPath
  }

  public var address: String {
    let hostname = host.contains(":") ? "[\(host)]" : host
    let destination = user.map { "\($0)@\(hostname)" } ?? hostname
    let portSuffix = port.map { ":\($0)" } ?? ""
    let path = socketPath == Self.defaultSocketPath ? "" : socketPath
    var components = URLComponents()
    components.path = path
    return "\(Self.scheme)://\(destination)\(portSuffix)\(components.percentEncodedPath)"
  }
}

public enum DockerSSHHostError: Error, LocalizedError, Sendable {
  case invalidAddress

  public var errorDescription: String? {
    "Enter ssh://user@server[:port], an SSH config alias, or an SSH URL with an absolute Docker socket path. Passwords and SSH options are not accepted."
  }
}
