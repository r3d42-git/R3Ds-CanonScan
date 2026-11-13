import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import CanonScan

final class DocumentEnhancerTests: XCTestCase {
    private let width = 640, height = 900
    private func fixture() throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width { pixels[y * width + x] = UInt8(238 + x % 13) }
        }
        // Realistic text strokes, a thin rule and a deliberate gray table fill.
        for y in 120..<150 { for x in 80..<380 where x % 18 < 8 { pixels[y * width + x] = 45 } }
        for x in 80..<500 { pixels[240 * width + x] = 100 }
        for y in 400..<450 { for x in 80..<400 { pixels[y * width + x] = 160 } }
        // Low-contrast but genuine ink must survive the grayscale treatment.
        for y in 600..<615 { for x in 80..<400 where x % 20 < 8 { pixels[y * width + x] = 190 } }
        return try DocumentEnhancer.grayscaleImage(pixels, width: width, height: height)
    }
    private func bytes(_ image: CGImage) -> [UInt8] { Array(image.dataProvider!.data! as Data) }

    func testGrayscaleRemovesPaperHazeButRetainsInkGrayFillAndResolution() throws {
        let original = try fixture()
        let result = try DocumentEnhancer.process(original, dpi: 300, appearance: .gray)
        XCTAssertEqual(result.width, width); XCTAssertEqual(result.height, height)
        XCTAssertEqual(result.colorSpace?.model, .monochrome)
        let p = bytes(result)
        for x in 30..<610 { XCTAssertGreaterThanOrEqual(p[60 * result.bytesPerRow + x], 252) }
        XCTAssertLessThan(p[130 * result.bytesPerRow + 90], 75)
        XCTAssertLessThan(p[240 * result.bytesPerRow + 200], 130)
        XCTAssertLessThan(p[420 * result.bytesPerRow + 200], 190)
        XCTAssertGreaterThan(p[420 * result.bytesPerRow + 200], 70)
        XCTAssertLessThan(p[605 * result.bytesPerRow + 100], 230)
    }

    func testSoftwareBlackAndWhiteKeepsFineStrokesAndHasOnlyBinaryPixels() throws {
        let result = try DocumentEnhancer.process(fixture(), dpi: 300, appearance: .blackAndWhite)
        let p = bytes(result)
        XCTAssertEqual(Set(p), Set([UInt8(0), UInt8(255)]))
        XCTAssertEqual(p[60 * result.bytesPerRow + 200], 255)
        XCTAssertEqual(p[130 * result.bytesPerRow + 90], 0)
        XCTAssertEqual(p[240 * result.bytesPerRow + 200], 0)
        XCTAssertEqual(p[605 * result.bytesPerRow + 100], 0)
    }

    func testOriginalAndModeRoundTripNeverRewriteSourceImage() throws {
        let image = try fixture(), original = bytes(image)
        let unchanged = try DocumentEnhancer.process(image, dpi: 300, appearance: .original)
        XCTAssertEqual(bytes(unchanged), original)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.png")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, nil); XCTAssertTrue(CGImageDestinationFinalize(writer))
        let sourceData = try Data(contentsOf: url)
        var page = ScanPage(imageURL: url, dpi: 300, cleanScannerEdges: false, appearance: .gray)
        let first = try PageImage.load(page)
        page.appearance = .blackAndWhite
        _ = try PageImage.load(page)
        page.appearance = .gray
        let restored = try PageImage.load(page)
        XCTAssertEqual(bytes(restored), bytes(first))
        XCTAssertEqual(try Data(contentsOf: url), sourceData)
        page.appearance = .original
        XCTAssertEqual(bytes(try PageImage.load(page)), original)
    }

    /// File-only acceptance test: no USB, no acquisition, no edits to input PDFs.
    func testUserQualityFixtures() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let input = environment["CANONSCAN_QUALITY_FIXTURE"], let output = environment["CANONSCAN_QUALITY_OUTPUT"] else {
            throw XCTSkip("Set CANONSCAN_QUALITY_FIXTURE and CANONSCAN_QUALITY_OUTPUT to review existing test scans.")
        }
        let directory = URL(fileURLWithPath: input), out = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for mode in [PageAppearance.original, .gray, .blackAndWhite] {
            let pages = (1...4).map { ScanPage(imageURL: directory.appendingPathComponent(String(format: "page-%06d.png", $0)), dpi: 300, appearance: mode) }
            let destination = out.appendingPathComponent("CanonScan-Vergleich-\(mode.rawValue).pdf")
            let began = Date()
            try PDFService.export(pages: pages, to: destination, recognizeText: true)
            let document = try XCTUnwrap(PDFDocument(url: destination))
            XCTAssertEqual(document.pageCount, 4)
            for (index, token) in ["ALPHA", "BRAVO", "CHARLIE", "DELTA"].enumerated() {
                XCTAssertTrue((document.page(at: index)?.string ?? "").uppercased().contains(token), "\(mode): page \(index + 1)")
                XCTAssertEqual(document.page(at: index)!.bounds(for: .mediaBox).width, 595.2, accuracy: 0.1)
                XCTAssertEqual(document.page(at: index)!.bounds(for: .mediaBox).height, 841.92, accuracy: 0.1)
            }
            print("\(mode): \(Date().timeIntervalSince(began)) seconds, \(destination.path)")
        }
    }
}
