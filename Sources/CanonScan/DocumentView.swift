import AppKit
import SwiftUI

struct DocumentView: View {
    @State private var applicationActive = NSApp.isActive
    @ObservedObject var settings: SettingsStore
    @StateObject private var model = DocumentModel()
    @StateObject private var previewZoom = PreviewZoomState()
    @State private var showDiagnostics = false
    @State private var showOptions = false
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, page in
                    PageRow(page: page, number: index + 1).tag(page.id)
                        .contextMenu {
                            Toggle("Scanrand bereinigen", isOn: Binding(
                                get: { page.cleanScannerEdges },
                                set: { model.setEdgeCleaning($0, for: page.id) }))
                                .help("Bereinigt erkannte Einzugskanten in den optimierten Ansichten. Die Darstellung „Original“ bleibt unverändert.")
                                .disabled(model.busy || page.appearance == .original)
                            Divider()
                            Button("Nach rechts drehen") { model.selectedID = page.id; model.rotate() }
                            Button("Seite entfernen", role: .destructive) { model.selectedID = page.id; model.removeSelected() }
                        }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .navigationTitle("Seiten")
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 320)
            .safeAreaInset(edge: .bottom) {
                Text(model.pageCountLabel).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(12)
            }
        } detail: {
            VStack(spacing: 0) {
                if let page = model.selectedPage {
                    appearanceControls
                    PagePreview(page: page, zoom: previewZoom)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .safeAreaInset(edge: .bottom, spacing: 0) { pageControls.padding(8)
                            .frame(maxWidth: .infinity).background(.bar) }
                } else {
                    ContentUnavailableView {
                        Label("Dein nächstes Dokument", systemImage: "doc.viewfinder")
                    } description: {
                        Text("Lege die Seiten in den Scanner. Nach dem Einlesen kannst du sie ordnen, drehen und als durchsuchbare PDF sichern.")
                            .frame(maxWidth: 380)
                    } actions: {
                        Button(model.deviceID == nil ? "Scanner suchen" : "Scannen") {
                            guard !model.busy else { return }
                            if model.deviceID != nil { model.scan(settings: settings.options) }
                            else { model.discover() }
                        }
                        .disabled(model.busy)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                statusBar
            }
            .navigationTitle("R3Ds CanonScan")
            .navigationSubtitle(model.dirty ? "Ungesicherte Änderungen" : model.pageCountLabel)
        }
        .frame(minWidth: 760, minHeight: 500)
        #if DEBUG
        .frame(width: ProcessInfo.processInfo.arguments.contains("--compact") ? 760 : nil,
               height: ProcessInfo.processInfo.arguments.contains("--compact") ? 500 : nil)
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--light") ? .light : nil)
        .font(ProcessInfo.processInfo.arguments.contains("--large-type") ? .system(size: 20) : nil)
        #endif
        .focusedSceneObject(model)
        .focusedSceneObject(previewZoom)
        .toolbar { toolbar }
        .background(WindowCloseGuard(model: model))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            applicationActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            applicationActive = false
        }
        .onChange(of: hardwareButtonContext, initial: true) { _, context in
            model.updateHardwareButtonMonitoring(allowed: context.allowed, settings: context.settings)
        }
        .onDisappear { model.stopHardwareButtonMonitoring() }
        .task {
            #if DEBUG
            let fixtures = ["--demo", "--worst-case", "--empty", "--one", "--fixture-directory"]
            if ProcessInfo.processInfo.arguments.contains(where: { fixtures.contains($0) }) { return }
            #endif
            model.discover()
        }
        .confirmationDialog("Neuen Scan beginnen?", isPresented: $model.showNewConfirmation, titleVisibility: .visible) {
            Button("Verwerfen und neu beginnen", role: .destructive) { model.newDocument() }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Das aktuelle Dokument wurde noch nicht als PDF gesichert. Verwirf die Seiten, um mit einem leeren Dokument zu beginnen.") }
        .confirmationDialog("Fenster schließen?", isPresented: $model.showCloseConfirmation, titleVisibility: .visible) {
            Button(model.busy ? "Vorgang abbrechen und schließen" : "Ohne Sichern schließen", role: .destructive) { model.confirmClose() }
            Button("Abbrechen", role: .cancel) {}
        } message: { Text("Ungesicherte Seiten bleiben lokal auf diesem Mac und werden beim nächsten Start wiederhergestellt.") }
        .alert(item: $model.alert) { alert in
            if alert.isOCR {
                return Alert(title: Text(alert.title), message: Text(alert.message), primaryButton: .default(Text("Erneut versuchen")) {
                    model.retryExport(recognizeText: true)
                }, secondaryButton: .default(Text("Ohne Texterkennung sichern")) {
                    model.retryExport(recognizeText: false)
                })
            }
            return Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .sheet(isPresented: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Diagnose").font(.title2).bold()
                Text("Technische Meldungen des letzten Vorgangs").foregroundStyle(.secondary)
                ScrollView { Text(model.diagnostics.isEmpty ? "Keine Meldungen vorhanden." : model.diagnostics).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Schließen") { showDiagnostics = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 620, height: 420)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.requestNew() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.badge.plus")
                    Text("Neuer Scan")
                }
                .accessibilityElement(children: .combine)
            }
            .help("Die aktuellen Seiten verwerfen und mit einem leeren Dokument beginnen.")
            .disabled(model.busy || model.pages.isEmpty)
            Button { model.scan(settings: settings.options) } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.pages.isEmpty ? "scanner" : "plus")
                    Text(model.pages.isEmpty ? "Scannen" : "Weitere Seiten")
                }
                .accessibilityElement(children: .combine)
            }
            .keyboardShortcut("d", modifiers: [.command])
            .disabled(model.busy || model.deviceID == nil)
            Button { model.savePanel(recognizeText: settings.options.recognizeText) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("PDF sichern")
                }
                .accessibilityElement(children: .combine)
            }
            .keyboardShortcut("s")
            .disabled(model.busy || model.pages.isEmpty)
            Button { showOptions.toggle() } label: { Label("Scanoptionen", systemImage: "slider.horizontal.3") }
                .popover(isPresented: $showOptions) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Scanoptionen").font(.headline)
                        ScanSettingsView(store: settings)
                        if let message = model.hardwareButtonMessage {
                            Text(message).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Divider()
                        if model.devices.count > 1 {
                            Picker("Scanner", selection: $model.deviceID) {
                                ForEach(model.devices) { device in Text(device.name).tag(Optional(device.id)) }
                            }
                        } else {
                            Text(model.devices.first?.name ?? "Kein Scanner verbunden")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Button("Scanner suchen") { model.discover() }.disabled(model.busy)
                        Button("Diagnose anzeigen …") { showOptions = false; showDiagnostics = true }
                    }.padding(20).frame(width: 340)
                }
                .disabled(model.busy)
        }
    }

    private struct HardwareButtonContext: Equatable {
        let allowed: Bool
        let deviceID: String?
        let settings: ScanSettings
    }

    private var hardwareButtonContext: HardwareButtonContext {
        #if DEBUG
        let fixtures = ["--demo", "--worst-case", "--empty", "--one", "--fixture-directory"]
        let preview = ProcessInfo.processInfo.arguments.contains(where: { fixtures.contains($0) })
        #else
        let preview = false
        #endif
        return HardwareButtonContext(
            allowed: !preview && settings.hardwareButtonEnabled && !model.busy &&
                model.isKeyWindow && applicationActive &&
                model.alert == nil && !model.showNewConfirmation && !model.showCloseConfirmation &&
                !showOptions && !showDiagnostics,
            deviceID: model.deviceID, settings: settings.options)
    }

    private var appearanceControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Text("Darstellung").foregroundStyle(.secondary)
                appearancePicker
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 8) {
                Text("Darstellung").foregroundStyle(.secondary)
                appearancePicker
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var appearancePicker: some View {
        Picker("Darstellung für alle Seiten", selection: Binding(
            get: { model.documentAppearance }, set: { model.documentAppearance = $0 })) {
            ForEach(PageAppearance.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .frame(maxWidth: 420)
        .help("Ändert die Darstellung aller Seiten und die PDF-Ausgabe. Die Originaldateien bleiben erhalten.")
        .disabled(model.busy)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.hardwareButtonReady ? "\(model.status) · Scannertaste bereit" : model.status).font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).help(model.status).frame(maxWidth: .infinity, alignment: .leading)
            if model.busy { Button("Abbrechen") { model.cancel() } }
            if settings.options.recognizeText {
                Label("Text erkennen", systemImage: "text.viewfinder").font(.caption).foregroundStyle(.secondary)
                    .help("Deutsch und Englisch, vollständig auf diesem Mac")
                    .fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }

    private var pageControls: some View {
        HStack(spacing: 14) {
            Button { model.moveSelected(by: -1) } label: { Label("Nach vorne", systemImage: "arrow.up") }
                .disabled(model.selectedIndex == 0)
            Button { model.moveSelected(by: 1) } label: { Label("Nach hinten", systemImage: "arrow.down") }
                .disabled(model.selectedIndex == model.pages.count - 1)
            Divider().frame(height: 18)
            Button { model.rotate() } label: { Label("Drehen", systemImage: "rotate.right") }
            Button { model.removeSelected() } label: { Label("Entfernen", systemImage: "trash") }
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .disabled(model.busy)
    }
}

struct ScanSettingsView: View {
    @ObservedObject var store: SettingsStore
    var body: some View {
        Form {
            Picker("Auflösung", selection: $store.options.resolution) {
                ForEach(ScanSettings.resolutions, id: \.self) { Text("\($0) dpi").tag($0) }
            }
            Picker("Standardausgabe", selection: $store.options.mode) {
                ForEach([ScanMode.gray, .lineart]) { Text($0.title).tag($0) }
            }
            Text("Das Original wird in Graustufen erfasst. Die Ausgabe lässt sich nach dem Scan ändern.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Beidseitig scannen", isOn: $store.options.duplex)
            Toggle(isOn: $store.hardwareButtonEnabled) {
                Text("Scannertaste verwenden").fixedSize(horizontal: false, vertical: true)
            }
            Text("Die Starttaste am Scanner liest weitere Seiten ins aktive Dokument ein, solange die App im Vordergrund ist.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Text erkennen", isOn: $store.options.recognizeText)
            Text("Durchsuchbare PDF mit deutscher und englischer Texterkennung. Die Verarbeitung bleibt auf diesem Mac.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PageRow: View {
    let page: ScanPage
    let number: Int
    var body: some View {
        HStack(spacing: 10) {
            PageBitmap(page: page, maxPixels: 160).frame(width: 42, height: 58).clipped()
            VStack(alignment: .leading, spacing: 3) {
                Text("Seite \(number)").fontWeight(.medium)
                Text(page.label.isEmpty ? "\(page.dpi) dpi" : page.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).help(page.label)
            }
        }.padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct PageBitmap: View {
    let page: ScanPage
    let maxPixels: Int
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .accessibilityLabel("Eingelesene Dokumentseite")
            } else { ProgressView().controlSize(.small) }
        }
        .task(id: "\(page.imageURL.path):\(page.rotation):\(page.cleanScannerEdges):\(page.appearance.rawValue):\(page.dpi):\(maxPixels)") {
            image = nil
            let snapshot = page, size = maxPixels
            let bitmap = await Task.detached(priority: .userInitiated) {
                try? PageImage.load(snapshot, maxPixelSize: size)
            }.value
            guard !Task.isCancelled else { return }
            image = bitmap.map { NSImage(cgImage: $0, size: .zero) }
        }
    }
}

/// Intercepts close before SwiftUI discards the window-scoped document.
struct WindowCloseGuard: NSViewRepresentable {
    let model: DocumentModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attach = { [weak coordinator = context.coordinator] window in
            guard let coordinator else { return }
            coordinator.window = window
            window.delegate = coordinator
            Task { @MainActor in coordinator.model.isKeyWindow = window.isKeyWindow }
        }
        return view
    }
    func updateNSView(_ view: AttachmentView, context: Context) {}
    final class AttachmentView: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { attach?(window) } }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: DocumentModel
        weak var window: NSWindow?
        var allowed = false
        init(model: DocumentModel) { self.model = model }
        func windowDidBecomeKey(_ notification: Notification) { model.isKeyWindow = true }
        func windowDidResignKey(_ notification: Notification) { model.isKeyWindow = false }
        func windowWillClose(_ notification: Notification) {
            model.isKeyWindow = false
            model.stopHardwareButtonMonitoring()
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowed || (!model.busy && (!model.dirty || model.pages.isEmpty)) { return true }
            model.requestClose { [weak self] in
                self?.allowed = true
                self?.window?.performClose(nil)
            }
            return false
        }
    }
}
