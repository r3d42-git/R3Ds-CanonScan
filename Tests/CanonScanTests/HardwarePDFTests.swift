import Foundation
import PDFKit
import ImageIO
import XCTest
@testable import CanonScan

/// Opt-in, file-only integration test. This never opens a scanner or starts scanimage.
/// CANONSCAN_HARDWARE_FIXTURE=/absolute/path/to/four/pngs
/// CANONSCAN_HARDWARE_OUTPUT=/absolute/path/to/retained/pdf-output (optional)
final class HardwarePDFTests: XCTestCase {
    func testHardwareFixtureExportsSearchableAndImageOnlyPDF() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["CANONSCAN_HARDWARE_FIXTURE"], !path.isEmpty else {
            throw XCTSkip("Set CANONSCAN_HARDWARE_FIXTURE to the directory containing four completed scans.")
        }
        let fixture = URL(fileURLWithPath: path, isDirectory: true)
        let output = environment["CANONSCAN_HARDWARE_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fixture.appendingPathComponent("pdf-validation", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let pages = (1...4).map { ScanPage(imageURL: fixture.appendingPathComponent(String(format: "page-%06d.png", $0)), dpi: 300) }
        for page in pages { XCTAssertTrue(FileManager.default.fileExists(atPath: page.imageURL.path), page.imageURL.path) }
        let searchableURL = output.appendingPathComponent("CanonScan-Hardware-OCR-AN.pdf")
        let imageOnlyURL = output.appendingPathComponent("CanonScan-Hardware-OCR-AUS.pdf")
        try PDFService.export(pages: pages, to: searchableURL, recognizeText: true)
        try PDFService.export(pages: pages, to: imageOnlyURL, recognizeText: false)
        let searchable = try XCTUnwrap(PDFDocument(url: searchableURL))
        let imageOnly = try XCTUnwrap(PDFDocument(url: imageOnlyURL))
        let expected = ["ALPHA", "BRAVO", "CHARLIE", "DELTA"]
        for document in [searchable, imageOnly] {
            XCTAssertEqual(document.pageCount, 4)
            for index in 0..<4 {
                let page = try XCTUnwrap(document.page(at: index))
                XCTAssertEqual(page.bounds(for: .mediaBox).width, 595.2, accuracy: 0.6)
                XCTAssertEqual(page.bounds(for: .mediaBox).height, 841.92, accuracy: 0.6)
            }
        }
        for (index, word) in expected.enumerated() {
            let text = searchable.page(at: index)?.string ?? ""
            XCTAssertTrue(text.uppercased().contains(word), "Page \(index + 1): expected \(word), recognized: \(text)")
            XCTAssertFalse(searchable.findString(word, withOptions: [.caseInsensitive]).isEmpty)
            XCTAssertTrue((imageOnly.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        let uncorrectedPages = pages.map { page in
            var original = page; original.cleanScannerEdges = false; return original
        }
        try PDFService.export(pages: uncorrectedPages, to: output.appendingPathComponent("CanonScan-Hardware-OCR-AN-Originalraender.pdf"), recognizeText: true)
        try PDFService.export(pages: uncorrectedPages, to: output.appendingPathComponent("CanonScan-Hardware-OCR-AUS-Originalraender.pdf"), recognizeText: false)
        print("Retained corrected and original-edge hardware PDF examples in: \(output.path)")
    }
    func testHardwareFixtureEdgeMasksPreserveDimensionsAndOriginals() throws {
        guard let path = ProcessInfo.processInfo.environment["CANONSCAN_HARDWARE_FIXTURE"] else {
            throw XCTSkip("Set CANONSCAN_HARDWARE_FIXTURE to use the four existing test PNGs.")
        }
        var detectedCount = 0
        for number in 1...4 {
            let url = URL(fileURLWithPath: path).appendingPathComponent(String(format: "page-%06d.png", number))
            let originalData = try Data(contentsOf: url)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let correction = ScannerEdgeCleaner.detect(in: image, dpi: 300)
            if let correction {
                detectedCount += 1
                XCTAssertNotNil(number % 2 == 1 ? correction.top : correction.bottom)
                print("Page \(number) detected edge: top=\(String(describing: correction.top)), bottom=\(String(describing: correction.bottom))")
            } else {
                let unchanged = ScannerEdgeCleaner.clean(image, dpi: 300, enabled: true)
                XCTAssertEqual(unchanged.dataProvider!.data! as Data, image.dataProvider!.data! as Data)
                print("Page \(number): ambiguous or clipped edge, original preserved")
            }
            let corrected = ScannerEdgeCleaner.apply(correction, to: image)
            XCTAssertEqual(corrected.width, image.width); XCTAssertEqual(corrected.height, image.height)
            XCTAssertEqual(try Data(contentsOf: url), originalData)
        }
        XCTAssertGreaterThanOrEqual(detectedCount, 3, "The existing four-page fixture has three fully visible scanner edges; the clipped fourth edge is deliberately preserved.")
    }

}
