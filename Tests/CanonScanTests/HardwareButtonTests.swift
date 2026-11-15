import Foundation
import XCTest
@testable import CanonScan

final class HardwareButtonTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanonScan-Buttons-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for button/scan state")
    }

    @MainActor func testButtonScansWithCurrentSettingsAndAppendsToExistingDocument() async throws {
        let button = ButtonFixture(), scanner = ButtonScannerFixture()
        let model = DocumentModel(service: scanner, buttonService: button, session: directory, demoArguments: [])
        let existing = ScanPage(imageURL: directory.appendingPathComponent("existing.png"), dpi: 600, appearance: .blackAndWhite)
        model.append(existing)
        model.discover(); try await waitUntil { !model.busy }
        var settings = ScanSettings(); settings.resolution = 600; settings.duplex = false
        model.updateHardwareButtonMonitoring(allowed: true, settings: settings)
        try await waitUntil { model.hardwareButtonReady }
        button.press()
        try await waitUntil { scanner.scanCount == 1 && !model.busy }
        XCTAssertEqual(scanner.lastSettings, settings)
        XCTAssertEqual(model.pages.first, existing)
        XCTAssertEqual(model.pages.count, 2)
        XCTAssertEqual(model.pages.last?.appearance, .blackAndWhite)
        XCTAssertFalse(model.hardwareButtonReady)
        model.updateHardwareButtonMonitoring(allowed: true, settings: settings)
        try await waitUntil { model.hardwareButtonReady }
        button.press()
        try await waitUntil { scanner.scanCount == 2 && !model.busy }
        XCTAssertEqual(model.pages.count, 3)
        await model.stopHardwareButtonMonitoring()?.value
    }

    @MainActor func testManualScanWaitsUntilListenerHasReleasedDevice() async throws {
        let button = ButtonFixture(), scanner = ButtonScannerFixture()
        scanner.beforeScan = { XCTAssertEqual(button.openCount, 0, "USB listener must close before scanimage opens") }
        let model = DocumentModel(service: scanner, buttonService: button, session: directory, demoArguments: [])
        model.discover(); try await waitUntil { !model.busy }
        model.updateHardwareButtonMonitoring(allowed: true, settings: ScanSettings())
        try await waitUntil { model.hardwareButtonReady }
        model.scan(settings: ScanSettings())
        try await waitUntil { !model.busy }
        XCTAssertEqual(scanner.scanCount, 1)
        XCTAssertEqual(button.openCount, 0)
        XCTAssertFalse(model.hardwareButtonReady)
    }

    @MainActor func testDisabledListenerAndStalePressCannotStartScan() async throws {
        let button = ButtonFixture(), scanner = ButtonScannerFixture()
        let model = DocumentModel(service: scanner, buttonService: button, session: directory, demoArguments: [])
        model.discover(); try await waitUntil { !model.busy }
        model.updateHardwareButtonMonitoring(allowed: true, settings: ScanSettings())
        try await waitUntil { model.hardwareButtonReady }
        model.updateHardwareButtonMonitoring(allowed: false, settings: ScanSettings())
        button.press()
        await model.stopHardwareButtonMonitoring()?.value
        XCTAssertEqual(scanner.scanCount, 0)
        XCTAssertEqual(button.openCount, 0)
        XCTAssertFalse(model.hardwareButtonReady)
    }

    @MainActor func testWindowHandoffJoinsPreviousListenerBeforeOpeningNext() async throws {
        let firstButton = ButtonFixture(), secondButton = ButtonFixture()
        let firstScanner = ButtonScannerFixture(), secondScanner = ButtonScannerFixture()
        let first = DocumentModel(service: firstScanner, buttonService: firstButton,
                                  session: directory.appendingPathComponent("first"), demoArguments: [])
        let second = DocumentModel(service: secondScanner, buttonService: secondButton,
                                   session: directory.appendingPathComponent("second"), demoArguments: [])
        first.discover(); try await waitUntil { !first.busy }
        second.discover(); try await waitUntil { !second.busy }
        first.updateHardwareButtonMonitoring(allowed: true, settings: ScanSettings())
        try await waitUntil { first.hardwareButtonReady }
        secondButton.beforeOpen = { XCTAssertEqual(firstButton.openCount, 0) }
        second.updateHardwareButtonMonitoring(allowed: true, settings: ScanSettings())
        try await waitUntil { second.hardwareButtonReady }
        firstButton.press(); secondButton.press()
        try await waitUntil { secondScanner.scanCount == 1 && !second.busy }
        XCTAssertEqual(firstScanner.scanCount, 0)
        await first.stopHardwareButtonMonitoring()?.value
        await second.stopHardwareButtonMonitoring()?.value
    }

    @MainActor func testUnsupportedButtonDoesNotBlockManualScanOrShowAlert() async throws {
        let button = ButtonFixture(), scanner = ButtonScannerFixture()
        button.unsupported = true
        let model = DocumentModel(service: scanner, buttonService: button, session: directory, demoArguments: [])
        model.discover(); try await waitUntil { !model.busy }
        model.updateHardwareButtonMonitoring(allowed: true, settings: ScanSettings())
        try await waitUntil { model.hardwareButtonMessage != nil }
        XCTAssertNil(model.alert)
        XCTAssertFalse(model.hardwareButtonReady)
        model.scan(settings: ScanSettings())
        try await waitUntil { !model.busy }
        XCTAssertEqual(scanner.scanCount, 1)
    }

    private func helper(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("helper-\(UUID())")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testProcessRequiresExplicitStartSignal() async throws {
        let executable = try helper("printf 'READY\\n'\nexit 0")
        let service = HardwareButtonService(executable: executable, configuration: directory)
        do {
            try await service.waitForStart(device: .init(id: "mock", name: "Mock")) {}
            XCTFail("Clean helper exit without START must not trigger a scan")
        } catch let error as ScannerFailure {
            XCTAssertTrue(error.message.contains("kein Startsignal"))
        }
    }

    func testProcessReportsReadyAndCancellationClosesListener() async throws {
        let executable = try helper("printf 'READY\\n'\nexec /bin/sleep 10")
        let service = HardwareButtonService(executable: executable, configuration: directory)
        let ready = expectation(description: "Button listener ready")
        let task = Task {
            try await service.waitForStart(device: .init(id: "mock", name: "Mock")) { ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 3)
        task.cancel()
        do { try await task.value; XCTFail("Cancelled wait must throw") }
        catch is CancellationError { }
    }

    func testProcessAcceptsStartOnlyAfterHelperExits() async throws {
        let executable = try helper("printf 'READY\\nSTART\\n'\nexit 0")
        let service = HardwareButtonService(executable: executable, configuration: directory)
        try await service.waitForStart(device: .init(id: "mock", name: "Mock")) {}
    }
}

private final class ButtonFixture: HardwareButtonServing, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pressed = false
    private var opened = 0
    var beforeOpen: (() -> Void)?
    var unsupported = false
    var openCount: Int { lock.withLock { opened } }
    func press() { lock.withLock { pressed = true } }
    func cancel() { lock.withLock { cancelled = true } }
    func waitForStart(device: ScannerDevice, onReady: @escaping @Sendable () -> Void) async throws {
        beforeOpen?()
        if unsupported { throw ScannerFailure.status(1, details: "start unsupported") }
        lock.withLock { opened += 1; cancelled = false; pressed = false }
        defer { lock.withLock { opened -= 1 } }
        onReady()
        while true {
            if Task.isCancelled || lock.withLock({ cancelled }) {
                // Simulate the driver's asynchronous USB cleanup.
                await Task.detached { try? await Task.sleep(for: .milliseconds(40)) }.value
                throw CancellationError()
            }
            if lock.withLock({ pressed }) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class ButtonScannerFixture: ScannerServing, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var settings: ScanSettings?
    var beforeScan: (() -> Void)?
    var scanCount: Int { lock.withLock { count } }
    var lastSettings: ScanSettings? { lock.withLock { settings } }
    func discover() async throws -> [ScannerDevice] { [.init(id: "canon_dr:mock", name: "P-208II")] }
    func cancel() {}
    func scan(device: ScannerDevice, settings: ScanSettings, directory: URL,
              onPage: @escaping @Sendable (URL) -> Void) async throws -> Int {
        beforeScan?()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appendingPathComponent("page-000001.png")
        try Data("fixture".utf8).write(to: page)
        lock.withLock { count += 1; self.settings = settings }
        onPage(page)
        return 1
    }
}
