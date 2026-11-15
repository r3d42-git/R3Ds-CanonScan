import Foundation

protocol HardwareButtonServing: AnyObject {
    func waitForStart(device: ScannerDevice, onReady: @escaping @Sendable () -> Void) async throws
    func cancel()
}

/// Uses a separate process so stopping the listener cannot cancel a scan.
final class HardwareButtonService: HardwareButtonServing {
    private let process: ScannerService
    init(executable: URL? = Bundle.main.url(forResource: "scanbutton", withExtension: nil),
         configuration: URL? = Bundle.main.resourceURL?.appendingPathComponent("sane.d", isDirectory: true)) {
        process = ScannerService(executable: executable, configuration: configuration)
    }
    func cancel() { process.cancel() }
    func waitForStart(device: ScannerDevice, onReady: @escaping @Sendable () -> Void) async throws {
        try await process.waitForStart(device: device, onReady: onReady)
    }
}

protocol ScannerServing: AnyObject {
    func discover() async throws -> [ScannerDevice]
    func scan(device: ScannerDevice, settings: ScanSettings, directory: URL,
              onPage: @escaping @Sendable (URL) -> Void) async throws -> Int
    func cancel()
}

/// A single service belongs to one document window. Only completed PNGs are delivered.
final class ScannerService: ScannerServing, @unchecked Sendable {
    private let lock = NSLock()
    private var running: Process?
    private var cancelled = false
    private let executable: URL?
    private let configuration: URL?

    init(executable: URL? = Bundle.main.url(forResource: "scanimage", withExtension: nil),
         configuration: URL? = Bundle.main.resourceURL?.appendingPathComponent("sane.d", isDirectory: true)) {
        self.executable = executable
        self.configuration = configuration
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = running
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func begin() { lock.lock(); cancelled = false; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func run(arguments: [String], onOutput: ((String) -> Void)? = nil,
                     poll: (() throws -> Void)? = nil) throws -> (Int32, String, String) {
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ScannerFailure(message: "Die Scannerkomponente fehlt. Bitte verwende die vollständig erstellte R3Ds CanonScan-App.", details: "scanimage resource unavailable")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outURL = temporary.appendingPathComponent("stdout"), errURL = temporary.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outURL), error = try FileHandle(forWritingTo: errURL)
        defer { try? output.close(); try? error.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        if let configuration { environment["SANE_CONFIG_DIR"] = configuration.path }
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = output
        process.standardError = error
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        running = process
        do { try process.run() } catch { running = nil; lock.unlock(); throw error }
        lock.unlock()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            lock.lock(); running = nil; lock.unlock()
        }
        while process.isRunning {
            if isCancelled { process.terminate() }
            if let onOutput { onOutput((try? String(contentsOf: outURL, encoding: .utf8)) ?? "") }
            try poll?()
            Thread.sleep(forTimeInterval: 0.12)
        }
        process.waitUntilExit()
        try poll?()
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        if isCancelled { throw CancellationError() }
        return (process.terminationStatus, stdout, String(stderr.suffix(24000)))
    }

    fileprivate func waitForStart(device: ScannerDevice, onReady: @escaping @Sendable () -> Void) async throws {
        begin()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { [self] in
                var ready = false
                let (status, output, error) = try run(arguments: ["--device-name", device.id], onOutput: { output in
                    if !ready && output.split(whereSeparator: \.isNewline).contains("READY") {
                        ready = true
                        onReady()
                    }
                })
                guard status == 0 else { throw ScannerFailure.status(status, details: error) }
                guard output.split(whereSeparator: \.isNewline).contains("START") else {
                    throw ScannerFailure(message: "Die Scannertaste hat kein Startsignal geliefert.", details: output + error)
                }
            }.value
        } onCancel: { self.cancel() }
    }

    func discover() async throws -> [ScannerDevice] {
        begin()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                let (status, output, error) = try run(arguments: ["--formatted-device-list=%d\t%m%n"])
                guard status == 0 else { throw ScannerFailure.status(status, details: error) }
                return ScannerDevice.parse(output)
            }.value
        } onCancel: { self.cancel() }
    }

    static func arguments(device: ScannerDevice, settings: ScanSettings, directory: URL) -> [String] {
        ["--device-name", device.id,
         "--source", settings.duplex ? "ADF Duplex" : "ADF Front",
         "--mode", ScanMode.gray.rawValue, "--resolution", String(settings.resolution),
         "--page-width=210", "--page-height=297", "-x", "210", "-y", "297", "--format=png",
         "--batch=\(directory.appendingPathComponent("page-%06d.png").path)", "--batch-print"]
    }

    func scan(device: ScannerDevice, settings: ScanSettings, directory: URL,
              onPage: @escaping @Sendable (URL) -> Void) async throws -> Int {
        begin()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { [self] in
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var seen = Set<String>()
                let (status, _, error) = try run(arguments: Self.arguments(device: device, settings: settings, directory: directory), poll: {
                    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension.lowercased() == "png" && $0.lastPathComponent.hasPrefix("page-") }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    for file in files where seen.insert(file.lastPathComponent).inserted { onPage(file) }
                })
                guard status == 0 || (status == 7 && !seen.isEmpty) else {
                    throw ScannerFailure.status(status, details: error)
                }
                if seen.isEmpty { throw ScannerFailure.status(7, details: error) }
                return seen.count
            }.value
        } onCancel: { self.cancel() }
    }
}
