import AppKit
import Foundation

@MainActor final class DocumentModel: ObservableObject {
    @Published private(set) var pages: [ScanPage] = []
    @Published var selectedID: UUID?
    @Published private(set) var devices: [ScannerDevice] = []
    @Published var deviceID: String?
    @Published private(set) var busy = false
    @Published private(set) var status = "Bereit zum Scannen"
    @Published private(set) var dirty = false
    @Published var alert: UserAlert?
    @Published var showNewConfirmation = false
    @Published var showCloseConfirmation = false
    @Published var diagnostics = ""
    private var revision = UUID()
    private let service: ScannerServing
    private var operation: Task<Void, Never>?
    private var deleted: [(ScanPage, Int)] = []
    private var activeScan: UUID?
    private var pendingExport: URL?
    private var pendingClose: (() -> Void)?
    private static var claimedSessions = Set<URL>()
    let session: URL
    var selectedPage: ScanPage? { pages.first { $0.id == selectedID } }
    var canUndo: Bool { !deleted.isEmpty && !busy }
    var selectedIndex: Int? { pages.firstIndex { $0.id == selectedID } }
    var pageCountLabel: String { pages.count == 1 ? "1 Seite" : "\(pages.count) Seiten" }

    init(service: ScannerServing = ScannerService(), session: URL? = nil, demoArguments: [String] = ProcessInfo.processInfo.arguments) {
        self.service = service
        let fixture = demoArguments.contains { ["--demo", "--worst-case", "--empty", "--one", "--fixture-directory"].contains($0) }
        self.session = session ?? (fixture ? FileManager.default.temporaryDirectory.appendingPathComponent("CanonScan-Preview-\(UUID().uuidString)", isDirectory: true) : Self.recoverableSession() ?? Self.newSessionURL())
        Self.claimedSessions.insert(self.session)
        if !fixture { restore() }
        try? FileManager.default.createDirectory(at: self.session, withIntermediateDirectories: true)
        #if DEBUG
        if let argument = demoArguments.firstIndex(of: "--fixture-directory"), demoArguments.indices.contains(argument + 1) {
            let directory = URL(fileURLWithPath: demoArguments[argument + 1], isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files.filter({ $0.pathExtension == "png" && $0.lastPathComponent.hasPrefix("page-") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                append(ScanPage(imageURL: file, dpi: 300))
            }
            status = "Vorschau mit Testscans"
        }
        if demoArguments.contains("--demo") || demoArguments.contains("--worst-case") || demoArguments.contains("--one") {
            makeDemo(worst: demoArguments.contains("--worst-case"), one: demoArguments.contains("--one"))
        }
        #endif
    }

    private static func newSessionURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CanonScan/Sessions/\(UUID().uuidString)", isDirectory: true)
    }
    private struct Manifest: Codable {
        let pages: [ScanPage]
        let selection: UUID?
        let dirty: Bool
    }
    private static func recoverableSession() -> URL? {
        let base = newSessionURL().deletingLastPathComponent()
        let directories = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return directories.filter { !claimedSessions.contains($0) }.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }.first { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("session.json")),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return false }
            return manifest.dirty && !manifest.pages.isEmpty
        }
    }
    private func restore() {
        guard let data = try? Data(contentsOf: session.appendingPathComponent("session.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
        pages = manifest.pages.filter { FileManager.default.fileExists(atPath: $0.imageURL.path) }
        selectedID = pages.contains { $0.id == manifest.selection } ? manifest.selection : pages.first?.id
        dirty = manifest.dirty
        if !pages.isEmpty { status = "Ungesichertes Dokument wiederhergestellt · \(pageCountLabel)" }
    }
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Manifest(pages: pages, selection: selectedID, dirty: dirty))
            try data.write(to: session.appendingPathComponent("session.json"), options: .atomic)
        } catch {
            diagnostics = error.localizedDescription
            alert = UserAlert(title: "Sitzung konnte nicht gesichert werden", message: "Die Wiederherstellung nach dem Beenden ist derzeit nicht möglich. Sichere dein Dokument als PDF, bevor du die App schließt.")
        }
    }
    private func changed() { dirty = true; revision = UUID(); status = "Ungesicherte Änderungen · \(pageCountLabel)"; persist() }
    func append(_ page: ScanPage) {
        guard !pages.contains(where: { $0.imageURL == page.imageURL }) else { return }
        pages.append(page)
        if selectedID == nil { selectedID = page.id }
        changed()
    }
    var documentAppearance: PageAppearance {
        get { pages.first?.appearance ?? .gray }
        set {
            guard !busy, pages.contains(where: { $0.appearance != newValue }) else { return }
            for index in pages.indices { pages[index].appearance = newValue }
            changed()
        }
    }
    func setEdgeCleaning(_ enabled: Bool, for pageID: UUID) {
        guard !busy, let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
        pages[index].cleanScannerEdges = enabled
        changed()
    }
    func rotate() {
        guard !busy, let index = selectedIndex else { return }
        pages[index].rotateClockwise(); changed()
    }
    func moveSelected(by offset: Int) {
        guard !busy, let from = selectedIndex, pages.indices.contains(from + offset) else { return }
        pages.swapAt(from, from + offset); changed()
    }
    func move(from offsets: IndexSet, to index: Int) {
        guard !busy else { return }
        pages.move(fromOffsets: offsets, toOffset: index); changed()
    }
    func removeSelected() {
        guard !busy, let index = selectedIndex else { return }
        deleted.append((pages[index], index))
        pages.remove(at: index)
        selectedID = pages.isEmpty ? nil : pages[min(index, pages.count - 1)].id
        changed()
    }
    func undoRemoval() {
        guard !busy, let snapshot = deleted.popLast() else { return }
        pages.insert(snapshot.0, at: min(snapshot.1, pages.count)); selectedID = snapshot.0.id; changed()
    }
    func requestNew() {
        guard !busy else { return }
        if dirty && !pages.isEmpty { showNewConfirmation = true } else { newDocument() }
    }
    func newDocument() {
        guard !busy else { return }
        pages.removeAll(); selectedID = nil; deleted.removeAll(); dirty = false
        revision = UUID(); status = "Bereit zum Scannen"; persist()
        // Source images intentionally remain in the local session for recovery.
    }
    func requestClose(_ close: @escaping () -> Void) {
        if busy || (dirty && !pages.isEmpty) {
            pendingClose = close; showCloseConfirmation = true
        } else { close() }
    }
    func confirmClose() { cancel(); pendingClose?(); pendingClose = nil }

    func discover() {
        guard !busy else { return }
        busy = true; status = "Scanner wird gesucht …"
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.operation = nil }
            do {
                self.devices = try await self.service.discover()
                if !self.devices.contains(where: { $0.id == self.deviceID }) { self.deviceID = self.devices.first?.id }
                self.status = self.devices.isEmpty ? "Kein Scanner gefunden. Auto Start auf OFF stellen und USB prüfen." : "Scanner bereit"
            } catch is CancellationError { self.status = "Suche abgebrochen" }
            catch { self.present(error) }
        }
    }
    func scan(settings: ScanSettings) {
        guard !busy else { return }
        guard let device = devices.first(where: { $0.id == deviceID }) else {
            alert = UserAlert(title: "Kein Scanner ausgewählt", message: "Verbinde den Scanner per USB, stelle Auto Start vor dem Anschließen auf OFF und klicke auf „Scanner suchen“.")
            return
        }
        busy = true; status = "Seiten werden eingelesen …"
        let appearance: PageAppearance = pages.isEmpty ? (settings.mode == .lineart ? .blackAndWhite : .gray) : documentAppearance
        let scanID = UUID()
        activeScan = scanID
        let directory = session.appendingPathComponent("batch-\(scanID)", isDirectory: true)
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.importCompletedPages(in: directory, dpi: settings.resolution, appearance: appearance); self.activeScan = nil; self.busy = false; self.operation = nil }
            do {
                let count = try await self.service.scan(device: device, settings: settings, directory: directory) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.activeScan == scanID else { return }
                        self.importCompletedPages(in: directory, dpi: settings.resolution, appearance: appearance)
                        self.status = "\(self.pages.count) Seiten eingelesen …"
                    }
                }
                self.status = count == 1 ? "Eine weitere Seite eingelesen" : "\(count) weitere Seiten eingelesen"
            } catch is CancellationError { self.status = "Scan abgebrochen. Eingelesene Seiten bleiben erhalten." }
            catch { self.present(error) }
        }
    }
    private func importCompletedPages(in directory: URL, dpi: Int, appearance: PageAppearance) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let completed = files.filter {
            $0.pathExtension.lowercased() == "png" && $0.lastPathComponent.hasPrefix("page-")
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Callback tasks can arrive in any order. Reconcile the whole batch, preserving
        // page identities/edits and the user's order of all earlier document pages.
        let batchPath = directory.standardizedFileURL.path
        let batchPages = pages.filter { $0.imageURL.deletingLastPathComponent().standardizedFileURL.path == batchPath }
        let known = Dictionary(uniqueKeysWithValues: batchPages.map { ($0.imageURL, $0) })
        let orderedBatch = completed.map { known[$0] ?? ScanPage(imageURL: $0, dpi: dpi, appearance: appearance) }
        let reconciled = pages.filter { $0.imageURL.deletingLastPathComponent().standardizedFileURL.path != batchPath } + orderedBatch
        guard reconciled != pages else { return }
        pages = reconciled
        if selectedID == nil { selectedID = pages.first?.id }
        changed()
    }
    func cancel() { service.cancel(); operation?.cancel() }
    func present(_ error: Error) {
        diagnostics = (error as? ScannerFailure)?.details ?? String(describing: error)
        status = "Vorgang konnte nicht abgeschlossen werden"
        alert = UserAlert(title: "Vorgang nicht abgeschlossen", message: error.localizedDescription)
    }

    func savePanel(recognizeText: Bool) {
        guard !busy, !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Scan.pdf"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            Task { @MainActor in self?.export(to: destination, recognizeText: recognizeText) }
        }
    }
    func retryExport(recognizeText: Bool) {
        guard let pendingExport else { return }
        export(to: pendingExport, recognizeText: recognizeText)
    }
    func export(to destination: URL, recognizeText: Bool) {
        guard !busy, !pages.isEmpty else { return }
        busy = true; pendingExport = destination
        status = recognizeText ? "PDF mit Texterkennung wird erstellt …" : "PDF wird erstellt …"
        let snapshot = pages, savedRevision = revision
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.operation = nil }
            do {
                let exportTask = Task.detached(priority: .userInitiated) { [weak self] in
                    try PDFService.export(pages: snapshot, to: destination, recognizeText: recognizeText,
                                          onProgress: { count in
                        Task { @MainActor [weak self] in self?.status = "PDF: Seite \(count) von \(snapshot.count)" }
                    }, isCancelled: { Task.isCancelled })
                }
                try await withTaskCancellationHandler { try await exportTask.value } onCancel: { exportTask.cancel() }
                if self.revision == savedRevision { self.dirty = false; self.persist() }
                self.status = "PDF gesichert: \(destination.lastPathComponent)"
                self.pendingExport = nil
            } catch is CancellationError { self.status = "PDF-Erstellung abgebrochen. Alle Seiten bleiben erhalten." }
            catch let error as PDFExportError {
                if case .recognition(_, let details) = error {
                    self.diagnostics = details
                    self.alert = UserAlert(title: "Texterkennung fehlgeschlagen", message: error.localizedDescription, isOCR: true)
                } else { self.present(error) }
            } catch { self.present(error) }
        }
    }

    #if DEBUG
    private func makeDemo(worst: Bool, one: Bool) {
        let count = one ? 1 : (worst ? 24 : 3)
        for index in 0..<count {
            let size = NSSize(width: 840, height: 1188)
            let image = NSImage(size: size)
            image.lockFocus()
            NSColor.white.setFill(); NSRect(origin: .zero, size: size).fill()
            let title = index == 0 && worst ? "Unterlagen zur Jahresabrechnung der Wohnungseigentümergemeinschaft München-Süd 2026" : "Dokument \(index + 1)"
            (title as NSString).draw(in: NSRect(x: 70, y: 970, width: 700, height: 140), withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
            ("CanonScan\nLokale Texterkennung · Deutsch und Englisch\n\nRechnung 2026 — Betrag 123,45 €\nDie Originalseiten bleiben in voller Qualität erhalten." as NSString)
                .draw(in: NSRect(x: 70, y: 620, width: 700, height: 300), withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let url = session.appendingPathComponent("demo-\(index).png")
                try? png.write(to: url)
                append(ScanPage(imageURL: url, dpi: 102, label: title))
            }
        }
        devices = [ScannerDevice(id: "demo", name: worst ? "Canon imageFORMULA P-208II – Dokumentenscanner am USB-Adapter im Arbeitszimmer" : "Canon imageFORMULA P-208II")]
        deviceID = devices.first?.id
        status = "Vorschau mit Beispieldaten"
    }
    #endif
}

struct UserAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var isOCR = false
}
