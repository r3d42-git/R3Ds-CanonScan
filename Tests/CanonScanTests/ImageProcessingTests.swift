import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CanonScan

final class ImageProcessingTests: XCTestCase {
    private let width = 1200, height = 1800, dpi = 150.0
    private func fixture(edges: Bool, broken: Bool = false, textOnly: Bool = false) -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        func dark(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            let offset = (y * width + x) * 4
            pixels[offset] = 10; pixels[offset + 1] = 10; pixels[offset + 2] = 10
        }
        if edges {
            for x in 0..<width where !broken || x % 100 < 75 {
                let y = 17 + x / 100
                for d in 0..<2 { dark(x, y + d); dark(x, height - 1 - y - d) }
            }
        }
        // A genuine frame at 12 mm must never enter the 8 mm detector.
        let inset = Int(dpi * 12 / 25.4)
        for x in inset..<(width - inset) { dark(x, inset); dark(x, height - 1 - inset) }
        for y in inset..<(height - inset) { dark(inset, y); dark(width - 1 - inset, y) }
        // Text near the edge: separate glyph-like strokes, neither continuous nor narrow.
        if textOnly {
            for x in 80..<1100 where x % 24 < 11 {
                for y in 14..<28 { dark(x, y) }
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func clippedFixture(broken: Bool = false, middleOnly: Bool = false) -> CGImage {
        var pixels = [UInt8](fixture(edges: false).dataProvider!.data! as Data)
        func set(_ x: Int, _ y: Int, _ value: UInt8 = 10) {
            guard x >= 0, x < width, y >= 0, y < height else { return }
            for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
        }
        if middleOnly {
            for x in 200..<900 { set(x, 10); set(x, height - 11) }
        } else {
            for x in 0..<width where !broken || x % 100 < 75 {
                let top = Int(floor(16 - Double(x) / 33))
                let bottom = Int(floor(16 - Double(width - 1 - x) / 33))
                for delta in 0..<2 { set(x, top + delta); set(x, height - 1 - bottom - delta) }
            }
        }
        // Non-dark content in the invisible continuation must not be whitened.
        set(1100, 3, 180); set(100, height - 4, 180)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
        let offset = y * image.bytesPerRow + x * 4
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
    func testSlantedTopAndBottomScannerEdgesRemovedWithoutChangingPageSizeOrInnerFrame() throws {
        let original = fixture(edges: true)
        let correction = try XCTUnwrap(ScannerEdgeCleaner.detect(in: original, dpi: dpi))
        XCTAssertNotNil(correction.top); XCTAssertNotNil(correction.bottom)
        let corrected = ScannerEdgeCleaner.apply(correction, to: original)
        XCTAssertEqual(corrected.width, width); XCTAssertEqual(corrected.height, height)
        for x in stride(from: 30, to: width - 30, by: 31) {
            let edge = 17 + x / 100
            XCTAssertEqual(pixel(corrected, x, edge), [255, 255, 255, 255])
            XCTAssertEqual(pixel(corrected, x, height - 1 - edge), [255, 255, 255, 255])
        }
        let frame = Int(dpi * 12 / 25.4)
        XCTAssertEqual(pixel(corrected, 300, frame), pixel(original, 300, frame))
        XCTAssertEqual(pixel(corrected, 300, height - 1 - frame), pixel(original, 300, height - 1 - frame))
        XCTAssertEqual(pixel(original, 300, 20), [10, 10, 10, 255], "Original pixels must remain untouched")
    }
    func testClippedSlantedTopAndBottomEdgesFollowOnlyTheirVisibleBoundary() throws {
        let original = clippedFixture()
        let sourceBytes = original.dataProvider!.data! as Data
        let correction = try XCTUnwrap(ScannerEdgeCleaner.detect(in: original, dpi: dpi))
        let top = try XCTUnwrap(correction.top), bottom = try XCTUnwrap(correction.bottom)
        XCTAssertLessThan(top.depth(at: Double(width - 1)), 0)
        XCTAssertLessThan(bottom.depth(at: 0), 0)
        let corrected = ScannerEdgeCleaner.apply(correction, to: original)
        XCTAssertEqual(corrected.width, width); XCTAssertEqual(corrected.height, height)
        for x in stride(from: 30, to: 500, by: 31) {
            let edge = Int(floor(16 - Double(x) / 33))
            XCTAssertEqual(pixel(corrected, x, edge), [255, 255, 255, 255])
            XCTAssertEqual(pixel(corrected, width - 1 - x, height - 1 - edge), [255, 255, 255, 255])
        }
        XCTAssertEqual(pixel(corrected, 1100, 3), pixel(original, 1100, 3))
        XCTAssertEqual(pixel(corrected, 100, height - 4), pixel(original, 100, height - 4))
        let safeDepth = Int(ceil(dpi * 8 / 25.4))
        let correctedBytes = corrected.dataProvider!.data! as Data
        let interior = (safeDepth * width * 4)..<((height - safeDepth) * width * 4)
        XCTAssertEqual(correctedBytes.subdata(in: interior), sourceBytes.subdata(in: interior))
        XCTAssertEqual(original.dataProvider!.data! as Data, sourceBytes)
    }

    func testPartialMiddleLineWithoutBoundaryExitAndBrokenClippedLineStayUnchanged() {
        for image in [clippedFixture(middleOnly: true), clippedFixture(broken: true)] {
            XCTAssertNil(ScannerEdgeCleaner.detect(in: image, dpi: dpi))
            let corrected = ScannerEdgeCleaner.clean(image, dpi: dpi, enabled: true)
            XCTAssertEqual(corrected.dataProvider!.data! as Data, image.dataProvider!.data! as Data)
        }
    }

    /// File-only check of an already captured scan. Never opens a scanner or writes its PNG.
    func testOptInClippedHardwareFixturePreservesInteriorPixels() throws {
        guard let path = ProcessInfo.processInfo.environment["CANONSCAN_CLIPPED_EDGE_FIXTURE"] else {
            throw XCTSkip("Set CANONSCAN_CLIPPED_EDGE_FIXTURE to an existing raw PNG")
        }
        let url = URL(fileURLWithPath: path), sourceBytes = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let correction = try XCTUnwrap(ScannerEdgeCleaner.detect(in: image, dpi: 300))
        XCTAssertNotNil(correction.top)
        let result = ScannerEdgeCleaner.apply(correction, to: image)
        XCTAssertEqual(result.width, image.width); XCTAssertEqual(result.height, image.height)
        XCTAssertEqual(result.bitsPerPixel, image.bitsPerPixel)
        let original = image.dataProvider!.data! as Data, corrected = result.dataProvider!.data! as Data
        let channels = image.bitsPerPixel / 8
        for (x, y) in [(0, 25), (200, 20), (400, 13), (600, 8), (800, 3), (1000, 0)] {
            XCTAssertEqual(corrected[y * result.bytesPerRow + x * channels], 255)
        }
        let depth = Int(ceil(300 * 8 / 25.4))
        for y in depth..<(image.height - depth) {
            let sourceRow = original.subdata(in: (y * image.bytesPerRow)..<(y * image.bytesPerRow + image.width * channels))
            let outputRow = corrected.subdata(in: (y * result.bytesPerRow)..<(y * result.bytesPerRow + image.width * channels))
            XCTAssertEqual(outputRow, sourceRow, "Changed interior row \(y)")
        }
        // Check the exposed right portion of the top border, including its gray paper.
        for x in 1400..<image.width {
            for y in 0..<depth { XCTAssertEqual(corrected[y * result.bytesPerRow + x * channels], original[y * image.bytesPerRow + x * channels]) }
        }
        XCTAssertEqual(try Data(contentsOf: url), sourceBytes)
    }

    func testBrokenLineAndTextRemainUnchanged() {
        for image in [fixture(edges: true, broken: true), fixture(edges: false, textOnly: true), fixture(edges: false)] {
            XCTAssertNil(ScannerEdgeCleaner.detect(in: image, dpi: dpi))
            let corrected = ScannerEdgeCleaner.clean(image, dpi: dpi, enabled: true)
            XCTAssertEqual(corrected.dataProvider!.data! as Data, image.dataProvider!.data! as Data)
        }
    }
    func testDisabledCorrectionIsPixelIdentical() {
        let image = fixture(edges: true)
        let result = ScannerEdgeCleaner.clean(image, dpi: dpi, enabled: false)
        XCTAssertEqual(result.dataProvider!.data! as Data, image.dataProvider!.data! as Data)
    }
    func testOriginalDetectionScalesForThumbnail() throws {
        let original = fixture(edges: true)
        let correction = try XCTUnwrap(ScannerEdgeCleaner.detect(in: original, dpi: dpi))
        let context = CGContext(data: nil, width: width / 2, height: height / 2, bitsPerComponent: 8, bytesPerRow: width * 2,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(original, in: CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let thumbnail = context.makeImage()!
        let corrected = ScannerEdgeCleaner.apply(correction, to: thumbnail)
        XCTAssertEqual(corrected.width, width / 2); XCTAssertEqual(corrected.height, height / 2)
        XCTAssertEqual(pixel(corrected, 150, 10), [255, 255, 255, 255])
    }
    func testOldPageManifestDefaultsToReversibleEdgeCleaning() throws {
        let old = """
        {"id":"62A2B12D-D127-4D1E-8D16-4685BF06FA18","imageURL":"file:///tmp/scan.png","dpi":300,"rotation":0,"label":"Seite"}
        """
        let page = try JSONDecoder().decode(ScanPage.self, from: Data(old.utf8))
        XCTAssertTrue(page.cleanScannerEdges)
        var disabled = page; disabled.cleanScannerEdges = false
        let restored = try JSONDecoder().decode(ScanPage.self, from: JSONEncoder().encode(disabled))
        XCTAssertFalse(restored.cleanScannerEdges)
    }

    func testCorrectionPreservesGrayscaleChannelsAndDocumentPixels() throws {
        var pixels = [UInt8](repeating: 235, count: width * height)
        for x in 0..<width { pixels[20 * width + x] = 10 }
        pixels[200 * width + 200] = 47
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        let result = ScannerEdgeCleaner.clean(image, dpi: dpi, enabled: true)
        XCTAssertEqual(result.colorSpace?.model, .monochrome)
        XCTAssertEqual(result.bitsPerPixel, 8, "Do not triple document PDF data by converting grayscale to RGB")
        let bytes = try XCTUnwrap(result.dataProvider?.data) as Data
        XCTAssertEqual(bytes[20 * result.bytesPerRow + 200], 255)
        XCTAssertEqual(bytes[200 * result.bytesPerRow + 200], 47)
        XCTAssertEqual(bytes[200 * result.bytesPerRow + 300], 235)
    }
}
