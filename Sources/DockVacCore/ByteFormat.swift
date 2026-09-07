import Foundation

/// Decimal (SI) byte formatting that matches how Docker itself reports sizes.
public enum ByteFormat {
  private static let units = ["B", "kB", "MB", "GB", "TB", "PB"]

  /// Formats bytes with decimal units, e.g. `263 B`, `7.8 MB`, `1.05 GB`.
  public static func string(_ bytes: UInt64) -> String {
    if bytes < 1_000 {
      return "\(bytes) B"
    }
    var value = Double(bytes)
    var unitIndex = 0
    while value >= 1_000, unitIndex < units.count - 1 {
      value /= 1_000
      unitIndex += 1
    }
    return "\(formatNumber(value)) \(units[unitIndex])"
  }

  /// Formats an optional size, showing a placeholder when the daemon could not compute it.
  public static func string(_ bytes: UInt64?, unknown: String = "unknown size") -> String {
    guard let bytes else {
      return unknown
    }
    return string(bytes)
  }

  private static func formatNumber(_ value: Double) -> String {
    // Two decimals below 10, one below 100, none above; strip trailing zeros.
    let digits = value < 10 ? 2 : (value < 100 ? 1 : 0)
    var text = String(format: "%.\(digits)f", value)
    if text.contains(".") {
      while text.hasSuffix("0") {
        text.removeLast()
      }
      if text.hasSuffix(".") {
        text.removeLast()
      }
    }
    return text
  }

  /// Formats a count with its noun, e.g. `1 image`, `12 images`.
  public static func count(_ value: Int, singular: String, plural: String) -> String {
    value == 1 ? "1 \(singular)" : "\(value) \(plural)"
  }
}
