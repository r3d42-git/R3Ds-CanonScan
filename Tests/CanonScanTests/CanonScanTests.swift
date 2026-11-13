import AppKit
import PDFKit
import CoreText
import XCTest
@testable import CanonScan

final class CanonScanTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanonScanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func image() throws -> URL {
        let width = 1200, height = 600
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        let url = directory.appendingPathComponent("\(UUID().uuidString).png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    func testVisionRecognizesSyntheticPrintedPageLocally() throws {
        let context = CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 1600, height: 900))
        let text = NSAttributedString(string: "Rechnung 2026", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 100, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key: NSColor.black.cgColor])
        context.textPosition = CGPoint(x: 130, y: 550)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
        let url = directory.appendingPathComponent("printed.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        let data = try PDFService.create(pages: [ScanPage(imageURL: url, dpi: 300)], recognizeText: true)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertTrue(document.string?.contains("Rechnung") == true, document.string ?? "No recognized text")
        XCTAssertTrue(document.string?.contains("2026") == true)
    }

    func testMockProcessEmptyExitZeroIsNotSuccess() async throws {
        let executable = directory.appendingPathComponent("empty-scanner")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let service = ScannerService(executable: executable, configuration: directory)
        do {
            _ = try await service.scan(device: ScannerDevice(id: "mock", name: "Mock"), settings: ScanSettings(), directory: directory.appendingPathComponent("batch")) { _ in XCTFail("No completed image exists") }
            XCTFail("Empty feeder must not succeed")
        } catch let error as ScannerFailure {
            XCTAssertTrue(error.message.contains("kein Papier"))
        }
    }

    func testMockProcessOnlyDeliversFinalPNGAndAcceptsEndOfFeeder() async throws {
        let source = try image()
        let output = directory.appendingPathComponent("batch")
        let executable = directory.appendingPathComponent("fixture-scanner")
        let shell = """
        #!/bin/sh
        mkdir -p '\(output.path)'
        cp '\(source.path)' '\(output.path)/page-000001.png.part'
        mv '\(output.path)/page-000001.png.part' '\(output.path)/page-000001.png'
        cp '\(source.path)' '\(output.path)/page-000002.png.part'
        exit 7
        """
        try Data(shell.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let service = ScannerService(executable: executable, configuration: directory)
        let delivered = URLCollector()
        let count = try await service.scan(device: ScannerDevice(id: "mock", name: "Mock"), settings: ScanSettings(), directory: output) { delivered.add($0) }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(delivered.urls.map(\.lastPathComponent), ["page-000001.png"])
    }

    func testPDFDimensionsFollowDPIAndRotation() throws {
        let source = try image()
        let pages = [ScanPage(imageURL: source, dpi: 300), ScanPage(imageURL: source, dpi: 300, rotation: 90)]
        let data = try PDFService.create(pages: pages, recognizeText: false)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)!.bounds(for: .mediaBox).width, 288, accuracy: 0.01)
        XCTAssertEqual(document.page(at: 0)!.bounds(for: .mediaBox).height, 144, accuracy: 0.01)
        XCTAssertEqual(document.page(at: 1)!.bounds(for: .mediaBox).width, 144, accuracy: 0.01)
        XCTAssertEqual(document.page(at: 1)!.bounds(for: .mediaBox).height, 288, accuracy: 0.01)
    }

    func testOCRAddsSearchableInvisibleTextAndOffDoesNotCallRecognizer() throws {
        let pages = [ScanPage(imageURL: try image(), dpi: 300)]
        let recognizer = FixtureRecognizer()
        let on = try PDFService.create(pages: pages, recognizeText: true, recognizer: recognizer)
        let searchable = try XCTUnwrap(PDFDocument(data: on))
        XCTAssertTrue(searchable.string?.contains("Rechnung 2026") == true)
        XCTAssertEqual(searchable.findString("Rechnung", withOptions: []).count, 1)
        let off = try PDFService.create(pages: pages, recognizeText: false, recognizer: FailingRecognizer())
        let plain = try XCTUnwrap(PDFDocument(data: off))
        XCTAssertTrue((plain.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // Both render white; the text must not become visible on the scanned original.
        for document in [searchable, plain] {
            let bitmap = NSBitmapImageRep(cgImage: document.page(at: 0)!.thumbnail(of: NSSize(width: 288, height: 144), for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)!)
            var nonWhite = 0
            for y in stride(from: 8, to: bitmap.pixelsHigh - 8, by: 4) {
                for x in stride(from: 8, to: bitmap.pixelsWide - 8, by: 4) {
                    let color = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if color.redComponent < 0.95 || color.greenComponent < 0.95 || color.blueComponent < 0.95 { nonWhite += 1 }
                }
            }
            XCTAssertEqual(nonWhite, 0)
        }
    }

    func testOCRFailureNeverOverwritesDestination() throws {
        let destination = directory.appendingPathComponent("existing.pdf")
        let original = Data("important original".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try PDFService.create(pages: [ScanPage(imageURL: try image(), dpi: 300)], recognizeText: true, recognizer: FailingRecognizer()))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testCancelledExportLeavesExistingFileUntouched() throws {
        let destination = directory.appendingPathComponent("existing.pdf")
        let original = Data("important original".utf8)
        try original.write(to: destination)
        XCTAssertThrowsError(try PDFService.export(pages: [ScanPage(imageURL: try image(), dpi: 300)], to: destination, recognizeText: false, isCancelled: { true }))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testDeviceParsingAndBatchArguments() {
        let devices = ScannerDevice.parse("other:1\tOther scanner\ncanon_dr:libusb:016:008\tP-208II\n")
        XCTAssertEqual(devices.first?.id, "canon_dr:libusb:016:008")
        var settings = ScanSettings()
        settings.resolution = 600
        let args = ScannerService.arguments(device: devices[0], settings: settings, directory: directory)
        XCTAssertTrue(args.contains("ADF Duplex"))
        XCTAssertTrue(args.contains("--batch-print"))
        XCTAssertFalse(args.contains { $0.hasPrefix("--batch-count") })
        XCTAssertLessThan(args.firstIndex(of: "--page-height=297")!, args.firstIndex(of: "-y")!)
        settings.duplex = false
        XCTAssertTrue(ScannerService.arguments(device: devices[0], settings: settings, directory: directory).contains("ADF Front"))
    }

    @MainActor func testOrderingRotationRemovalUndoAndPersistence() throws {
        let first = ScanPage(imageURL: try image(), dpi: 300)
        let second = ScanPage(imageURL: try image(), dpi: 300)
        let session = directory.appendingPathComponent("session")
        let model = DocumentModel(service: MockScanner(), session: session, demoArguments: [])
        model.append(first); model.append(second)
        model.selectedID = first.id
        model.moveSelected(by: 1)
        XCTAssertEqual(model.pages.map(\.id), [second.id, first.id])
        for _ in 0..<5 { model.rotate() }
        XCTAssertEqual(model.selectedPage?.rotation, 90)
        model.removeSelected()
        XCTAssertEqual(model.pages.map(\.id), [second.id])
        model.undoRemoval()
        XCTAssertEqual(model.pages.map(\.id), [second.id, first.id])
        let restored = DocumentModel(service: MockScanner(), session: session, demoArguments: [])
        XCTAssertEqual(restored.pages, model.pages)
        XCTAssertTrue(restored.dirty)
        model.requestNew()
        XCTAssertTrue(model.showNewConfirmation)
        XCTAssertEqual(model.pages.count, 2)
    }

    @MainActor func testScannerFailureKeepsExistingPages() async throws {
        let existing = ScanPage(imageURL: try image(), dpi: 300)
        let model = DocumentModel(service: MockScanner(), session: directory.appendingPathComponent("session"), demoArguments: [])
        model.append(existing)
        model.discover()
        while model.busy { await Task.yield() }
        model.scan(settings: ScanSettings())
        while model.busy { await Task.yield() }
        XCTAssertEqual(model.pages, [existing])
        XCTAssertNotNil(model.alert)
    }
}

private struct FixtureRecognizer: TextRecognizing {
    func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        [RecognizedLine(text: "Rechnung 2026", bounds: CGRect(x: 0.1, y: 0.4, width: 0.7, height: 0.15))]
    }
}
private struct FailingRecognizer: TextRecognizing {
    func recognize(_ image: CGImage) throws -> [RecognizedLine] { throw CocoaError(.fileReadUnknown) }
}
private final class MockScanner: ScannerServing {
    func discover() async throws -> [ScannerDevice] { [ScannerDevice(id: "mock", name: "Testgerät")] }
    func scan(device: ScannerDevice, settings: ScanSettings, directory: URL, onPage: @escaping @Sendable (URL) -> Void) async throws -> Int {
        throw ScannerFailure.status(9, details: "mock disconnected")
    }
    func cancel() {}
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return storage }
    func add(_ url: URL) { lock.lock(); storage.append(url); lock.unlock() }
}
