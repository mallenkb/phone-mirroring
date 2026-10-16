import AppKit
import XCTest
@testable import PhoneRelay

/// The in-bar traffic lights must stay crisp on the white light-mode bar.
@MainActor
final class TrafficLightAppearanceTests: XCTestCase {
    func testLightModeUsesASameHueRimAndDarkModeASubtleOutline() throws {
        let button = MirrorTrafficLightButton(kind: .close)

        button.appearance = NSAppearance(named: .aqua)
        button.viewDidChangeEffectiveAppearance()
        let lightRim = try XCTUnwrap(button.layer?.borderColor.flatMap(NSColor.init(cgColor:)))
        let lightRGB = try XCTUnwrap(lightRim.usingColorSpace(.sRGB))
        XCTAssertEqual(lightRGB.alphaComponent, 1, accuracy: 0.01, "light-mode rim must be opaque")
        XCTAssertGreaterThan(lightRGB.redComponent, 0.8, "light-mode rim is a darker red, not gray")
        XCTAssertEqual(button.layer?.borderWidth ?? 0, 0.6, accuracy: 0.001)

        button.appearance = NSAppearance(named: .darkAqua)
        button.viewDidChangeEffectiveAppearance()
        let darkRim = try XCTUnwrap(button.layer?.borderColor.flatMap(NSColor.init(cgColor:)))
        XCTAssertLessThan(darkRim.alphaComponent, 0.5, "dark mode keeps a subtle outline")
    }

    func testAppearanceDetection() {
        XCTAssertTrue(MirrorTrafficLightButton.isDarkAppearance(NSAppearance(named: .darkAqua)!))
        XCTAssertFalse(MirrorTrafficLightButton.isDarkAppearance(NSAppearance(named: .aqua)!))
    }
}

/// The bar's action icons (pin, screenshot, files, home) must be readable on
/// both the light and the dark bar.
final class ChromeIconAppearanceTests: XCTestCase {
    func testIconsAreDarkOnTheLightBarAndLightOnTheDarkBar() throws {
        let light = try XCTUnwrap(MirrorChromeOutlineButton.idleIconColor(isDark: false).usingColorSpace(.sRGB))
        let dark = try XCTUnwrap(MirrorChromeOutlineButton.idleIconColor(isDark: true).usingColorSpace(.sRGB))
        XCTAssertLessThan(light.redComponent, 0.2, "light-mode icons must be dark")
        XCTAssertGreaterThan(light.alphaComponent, 0.5)
        XCTAssertGreaterThan(dark.redComponent, 0.8, "dark-mode icons stay light")
    }

    func testHoverHighlightIsVisibleOnEitherBar() throws {
        let lightHover = try XCTUnwrap(MirrorChromeOutlineButton.highlightColor(isDark: false, pressed: false).usingColorSpace(.sRGB))
        XCTAssertLessThan(lightHover.redComponent, 0.2, "a white highlight is invisible on the light bar")
        XCTAssertGreaterThan(
            MirrorChromeOutlineButton.highlightColor(isDark: false, pressed: true).alphaComponent,
            lightHover.alphaComponent
        )
    }
}
