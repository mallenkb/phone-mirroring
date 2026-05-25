import SwiftUI
import AppKit

/// Template-rendered SVG icon loaded from the bundled Lucide set.
struct LucideIcon: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let nsImage = LucideIcon.loadImage(name) {
                Image(nsImage: nsImage)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(Color.red.opacity(0.4))
            }
        }
        .frame(width: size, height: size)
    }

    private static func loadImage(_ name: String) -> NSImage? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg") else {
            return nil
        }
        let image = NSImage(contentsOf: url)
        image?.isTemplate = true
        return image
    }
}
