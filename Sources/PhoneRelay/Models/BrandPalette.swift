import AppKit
import SwiftUI

enum PhoneRelayBrand {
    static let deepCyanComponents = (red: 22.0 / 255.0, green: 78.0 / 255.0, blue: 99.0 / 255.0)
    static let cyanComponents = (red: 103.0 / 255.0, green: 232.0 / 255.0, blue: 249.0 / 255.0)

    static var deepCyanColor: Color {
        Color(
            red: deepCyanComponents.red,
            green: deepCyanComponents.green,
            blue: deepCyanComponents.blue
        )
    }

    static var cyanColor: Color {
        Color(
            red: cyanComponents.red,
            green: cyanComponents.green,
            blue: cyanComponents.blue
        )
    }

    static var deepCyanNSColor: NSColor {
        NSColor(
            srgbRed: deepCyanComponents.red,
            green: deepCyanComponents.green,
            blue: deepCyanComponents.blue,
            alpha: 1
        )
    }
}
