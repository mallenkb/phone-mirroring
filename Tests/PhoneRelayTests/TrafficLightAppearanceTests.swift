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
