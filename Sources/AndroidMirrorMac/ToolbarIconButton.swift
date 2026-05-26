import AppKit

final class ToolbarIconButton: NSButton {
    init(symbolName: String, accessibilityDescription: String) {
        super.init(frame: .zero)

        bezelStyle = .regularSquare
        isBordered = false
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )
        imagePosition = .imageOnly
        contentTintColor = NSColor.white.withAlphaComponent(0.78)
        toolTip = accessibilityDescription
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateLayer() {
        layer?.backgroundColor = isHighlighted
            ? NSColor.white.withAlphaComponent(0.16).cgColor
            : NSColor.white.withAlphaComponent(0.08).cgColor
    }
}
