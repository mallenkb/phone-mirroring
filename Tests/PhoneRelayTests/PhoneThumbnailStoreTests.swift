import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import PhoneRelay

final class PhoneThumbnailStoreTests: XCTestCase {
    func testDownscaledThumbnailReturnsBoundedPNGData() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneRelay-thumbnail-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 640,
            height: 480,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        let sourceImage = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            sourceURL as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, sourceImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let thumbnailData = try XCTUnwrap(PhoneThumbnailStore.downscaledPNGData(sourceURL))
        XCTAssertFalse(thumbnailData.isEmpty)
        let thumbnailSource = try XCTUnwrap(CGImageSourceCreateWithData(thumbnailData as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(thumbnailSource, 0, nil) as? [CFString: Any]
        )
        let width = try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        XCTAssertLessThanOrEqual(max(width, height), PhoneThumbnailStore.thumbnailPixelSize)
        XCTAssertEqual(width * 3, height * 4)
    }
}
