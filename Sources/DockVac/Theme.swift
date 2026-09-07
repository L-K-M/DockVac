import AppKit
import DockVacCore

/// Colours, symbols, and fonts shared by the views.
@MainActor
enum Theme {
  static func color(for kind: DockerResourceKind) -> NSColor {
    switch kind {
    case .images: return .systemBlue
    case .containers: return .systemTeal
    case .localVolumes: return .systemOrange
    case .buildCache: return .systemPurple
    }
  }

  static func color(for tone: UsageTone) -> NSColor {
    switch tone {
    case .reclaimable: return .systemGreen
    case .caution: return .systemOrange
    case .locked: return .secondaryLabelColor
    }
  }

  static func symbolName(for kind: DockerResourceKind) -> String {
    switch kind {
    case .images: return "shippingbox"
    case .containers: return "cube"
    case .localVolumes: return "externaldrive"
    case .buildCache: return "hammer"
    }
  }

  static func symbol(
    _ name: String, pointSize: CGFloat, weight: NSFont.Weight = .regular, color: NSColor? = nil
  ) -> NSImage? {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
      return nil
    }
    var configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    if let color {
      configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    }
    return image.withSymbolConfiguration(configuration)
  }

  static var treemapBackground: NSColor { .underPageBackgroundColor }
  static var panelBackground: NSColor { .controlBackgroundColor }

  static func label(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
  )
    -> NSTextField
  {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }

  static func wrappingLabel(
    _ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
  )
    -> NSTextField
  {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.isSelectable = true
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }
}
