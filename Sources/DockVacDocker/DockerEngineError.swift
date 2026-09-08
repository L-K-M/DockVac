import DockVacCore
import Foundation

/// Failures raised by the Docker driver. Messages are written for the user.
public enum DockerEngineError: Error, Hashable, Sendable, LocalizedError {
  /// The socket could not be opened or connected.
  case socketUnavailable(path: String, detail: String)
  /// No candidate socket answered. `attempts` lists each path and why it failed.
  case daemonNotFound(attempts: [String], unsupported: [String])
  case timedOut(path: String)
  case malformedResponse(String)
  /// The daemon answered with an HTTP error; `message` is Docker's own explanation.
  case api(status: Int, message: String)
  case decoding(DockerDecodingError)

  public var errorDescription: String? {
    switch self {
    case .socketUnavailable(let path, let detail):
      return "Could not connect to Docker at \(path): \(detail)"
    case .daemonNotFound(let attempts, let unsupported):
      var lines = ["Docker does not seem to be running."]
      if !attempts.isEmpty {
        lines.append("Tried: " + attempts.joined(separator: "; "))
      }
      if !unsupported.isEmpty {
        lines.append(
          "Only local unix sockets are supported, not " + unsupported.joined(separator: ", ") + ".")
      }
      return lines.joined(separator: "\n")
    case .timedOut(let path):
      return "Docker at \(path) did not answer in time."
    case .malformedResponse(let detail):
      return "Docker sent a response DockVac could not read: \(detail)"
    case .api(let status, let message):
      return message.isEmpty ? "Docker returned HTTP \(status)." : message
    case .decoding(let error):
      return error.errorDescription
    }
  }

  public var httpStatus: Int? {
    if case .api(let status, _) = self { return status }
    return nil
  }

  public var isNotFound: Bool { httpStatus == 404 }
  public var isConflict: Bool { httpStatus == 409 }
}

/// A user-facing message for any error thrown by the driver.
public func dockerErrorMessage(_ error: Error) -> String {
  if error is CancellationError {
    return "Cancelled."
  }
  if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
    return described
  }
  return String(describing: error)
}
