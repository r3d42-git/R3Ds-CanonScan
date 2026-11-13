import Foundation
import XCTest
@testable import CanonScan

final class ModelProcessingTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanonScan-ModelProcessing-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testOldPageManifestKeepsOriginalAppearanceAndAllExistingProperties() throws {
        let page = ScanPage(imageURL: directory.appendingPathComponent("source.png"), dpi: 600,
                            rotation: 90, label: "Alte Seite", cleanScannerEdges: false)
        XCTAssertEqual(page.appearance, .gray)
        let data = try JSONEncoder().encode(page)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "appearance")
        let restored = try JSONDecoder().decode(ScanPage.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.appearance, .original)
        XCTAssertEqual(restored.id, page.id)
        XCTAssertEqual(restored.imageURL, page.imageURL)
        XCTAssertEqual(restored.rotation, page.rotation)
        XCTAssertEqual(restored.label, page.label)
        XCTAssertEqual(restored.dpi, page.dpi)
        XCTAssertFalse(restored.cleanScannerEdges)
        for appearance in PageAppearance.allCases {
            var edited = page; edited.appearance = appearance
            XCTAssertEqual(try JSONDecoder().decode(ScanPage.self, from: JSONEncoder().encode(edited)), edited)
        }
    }

    @MainActor func testRestoringLegacySessionDoesNotRewriteManifestOrImage() throws {
        let source = directory.appendingPathComponent("legacy-source.png")
        let sourceBytes = Data("existing scan bytes".utf8)
        try sourceBytes.write(to: source)
        let page = ScanPage(imageURL: source, dpi: 300)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(page)) as? [String: Any])
        legacy.removeValue(forKey: "appearance")
        let session = directory.appendingPathComponent("legacy-session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let manifest = session.appendingPathComponent("session.json")
        let saved = try JSONSerialization.data(withJSONObject: ["pages": [legacy], "selection": page.id.uuidString, "dirty": true])
        try saved.write(to: manifest)
        let model = DocumentModel(service: ProcessingFixtureScanner(), session: session, demoArguments: [])
        XCTAssertEqual(model.pages.count, 1)
        XCTAssertEqual(model.documentAppearance, .original)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: manifest), saved)
    }

    func testAllOutputModesCaptureGrayOriginals() {
        for mode in ScanMode.allCases {
            var settings = ScanSettings(); settings.mode = mode
            let args = ScannerService.arguments(device: ScannerDevice(id: "mock", name: "Mock"), settings: settings, directory: directory)
            XCTAssertEqual(args[args.firstIndex(of: "--mode")! + 1], "Gray")
        }
    }

    @MainActor func testDocumentAppearanceChangesAllPagesPersistsAndKeepsSourceBytes() throws {
        let source = directory.appendingPathComponent("original.png")
        let bytes = Data("unchanged original image".utf8)
        try bytes.write(to: source)
        let first = ScanPage(imageURL: source, dpi: 300, rotation: 90, label: "Erste", cleanScannerEdges: false)
        let other = directory.appendingPathComponent("other.png"); try bytes.write(to: other)
        let second = ScanPage(imageURL: other, dpi: 300, appearance: .original)
        let session = directory.appendingPathComponent("session")
        let model = DocumentModel(service: ProcessingFixtureScanner(), session: session, demoArguments: [])
        model.append(first); model.append(second)
        model.documentAppearance = .blackAndWhite
        XCTAssertTrue(model.dirty)
        XCTAssertEqual(model.pages.map(\.appearance), [.blackAndWhite, .blackAndWhite])
        XCTAssertEqual(model.pages.map(\.imageURL), [source, other])
        XCTAssertEqual(model.pages.first?.id, first.id)
        XCTAssertEqual(model.pages.first?.rotation, 90)
        XCTAssertEqual(model.pages.first?.label, "Erste")
        XCTAssertEqual(model.pages.first?.cleanScannerEdges, false)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let restored = DocumentModel(service: ProcessingFixtureScanner(), session: session, demoArguments: [])
        XCTAssertEqual(restored.pages, model.pages)
        XCTAssertEqual(restored.documentAppearance, .blackAndWhite)
    }

    @MainActor func testShuffledDuplicateCallbacksReconcileOnlyNewBatchAndInheritAppearance() async throws {
        let model = DocumentModel(service: ProcessingFixtureScanner(), session: directory.appendingPathComponent("session"), demoArguments: [])
        let one = ScanPage(imageURL: directory.appendingPathComponent("existing-one.png"), dpi: 600, rotation: 180, appearance: .original)
        let two = ScanPage(imageURL: directory.appendingPathComponent("existing-two.png"), dpi: 300, appearance: .original)
        model.append(one); model.append(two)
        model.moveSelected(by: 1)
        let existing = model.pages
        model.discover(); try await finish(model)
        var settings = ScanSettings(); settings.mode = .lineart
        model.scan(settings: settings)
        model.documentAppearance = .blackAndWhite // Busy documents must reject edits.
        try await finish(model)
        XCTAssertEqual(Array(model.pages.prefix(2)), existing)
        XCTAssertEqual(model.pages.dropFirst(2).map { $0.imageURL.lastPathComponent },
                       ["page-000001.png", "page-000002.png", "page-000003.png", "page-000004.png"])
        XCTAssertEqual(Set(model.pages.map(\.imageURL)).count, 6)
        XCTAssertTrue(model.pages.allSatisfy { $0.appearance == .original })
    }

    @MainActor func testEmptyDocumentUsesRequestedOutputAppearance() async throws {
        for mode in [ScanMode.gray, .lineart] {
            let model = DocumentModel(service: ProcessingFixtureScanner(), session: directory.appendingPathComponent(UUID().uuidString), demoArguments: [])
            model.discover(); try await finish(model)
            var settings = ScanSettings(); settings.mode = mode
            model.scan(settings: settings); try await finish(model)
            XCTAssertEqual(model.pages.count, 4)
            XCTAssertTrue(model.pages.allSatisfy { $0.appearance == (mode == .lineart ? .blackAndWhite : .gray) })
        }
    }

    @MainActor func testLateCallbacksAfterCancellationAndNewDocumentCannotRestoreOldBatch() async throws {
        let scanner = LateCallbackFixtureScanner()
        let model = DocumentModel(service: scanner, session: directory.appendingPathComponent("cancel-session"), demoArguments: [])
        model.discover(); try await finish(model)
        model.scan(settings: ScanSettings())
        let deadline = ContinuousClock.now + .seconds(3)
        while model.pages.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(model.pages.count, 1)
        model.newDocument()
        XCTAssertEqual(model.pages.count, 1, "An active scan must prevent clearing its document")
        model.cancel(); try await finish(model)
        XCTAssertEqual(model.pages.count, 1, "Cancellation keeps completed pages")
        model.newDocument()
        XCTAssertTrue(model.pages.isEmpty)
        try scanner.deliverLate()
        // Queue a main-actor turn after the stale callback, then allow its Task to drain.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(model.pages.isEmpty)
        XCTAssertFalse(model.dirty)
    }

    @MainActor private func finish(_ model: DocumentModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.busy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        XCTAssertFalse(model.busy, "Mock scanner did not finish")
        XCTAssertNil(model.alert)
    }
}

private final class ProcessingFixtureScanner: ScannerServing {
    func discover() async throws -> [ScannerDevice] { [ScannerDevice(id: "mock", name: "Mock")] }
    func scan(device: ScannerDevice, settings: ScanSettings, directory: URL,
              onPage: @escaping @Sendable (URL) -> Void) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for number in [2, 1, 4, 3, 2] {
            let file = directory.appendingPathComponent(String(format: "page-%06d.png", number))
            try Data("file-only model fixture".utf8).write(to: file, options: .atomic)
            onPage(file)
            await Task.yield()
        }
        return 4
    }
    func cancel() {}
}

private final class LateCallbackFixtureScanner: ScannerServing, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var delivery: (@Sendable (URL) -> Void)?
    private var batch: URL?
    func discover() async throws -> [ScannerDevice] { [ScannerDevice(id: "mock", name: "Mock")] }
    func scan(device: ScannerDevice, settings: ScanSettings, directory: URL,
              onPage: @escaping @Sendable (URL) -> Void) async throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        lock.withLock { batch = directory; delivery = onPage }
        let first = directory.appendingPathComponent("page-000001.png")
        try Data("completed before cancellation".utf8).write(to: first)
        onPage(first)
        while lock.withLock({ !cancelled }) { try await Task.sleep(for: .milliseconds(2)) }
        throw CancellationError()
    }
    func cancel() { lock.withLock { cancelled = true } }
    func deliverLate() throws {
        let (directory, callback) = lock.withLock { (batch, delivery) }
        let file = try XCTUnwrap(directory).appendingPathComponent("page-000002.png")
        try Data("late scanner page".utf8).write(to: file)
        callback?(file)
    }
}
