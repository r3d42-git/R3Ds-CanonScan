import AppKit
import SwiftUI

enum PreviewZoomMode: Equatable { case fitPage, fitWidth, custom }

/// Preview-only, owned by one document window. Never mutates the scan or PDF state.
@MainActor final class PreviewZoomState: ObservableObject {
    @Published private(set) var mode: PreviewZoomMode = .fitPage
    @Published private(set) var scale: CGFloat = 1
    func fitPage() { mode = .fitPage }
    func fitWidth() { mode = .fitWidth }
    func setScale(_ value: CGFloat) { scale = PreviewZoomGeometry.clamp(value); mode = .custom }
    func zoomIn() { setScale(scale * 1.25) }
    func zoomOut() { setScale(scale / 1.25) }
    func reportFitScale(_ value: CGFloat, mode expected: PreviewZoomMode) {
        guard mode == expected, mode != .custom else { return }
        let value = PreviewZoomGeometry.clamp(value)
        if abs(scale - value) > 0.0001 { scale = value }
    }
}

enum PreviewZoomGeometry {
    static let minimum: CGFloat = 0.1
    static let maximum: CGFloat = 8
    static func clamp(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return 1 }
        return min(maximum, max(minimum, scale))
    }
    static func valid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
    /// PageImage.load already rotates its pixels; do not rotate these dimensions again.
    static func pointSize(rotatedPixels: CGSize, dpi: Int) -> CGSize {
        guard valid(rotatedPixels), dpi > 0 else { return CGSize(width: 612, height: 792) }
        return CGSize(width: rotatedPixels.width * 72 / CGFloat(dpi), height: rotatedPixels.height * 72 / CGFloat(dpi))
    }
    static func scale(mode: PreviewZoomMode, custom: CGFloat, page: CGSize, viewport: CGSize) -> CGFloat {
        guard mode != .custom else { return clamp(custom) }
        guard valid(page), valid(viewport) else { return 1 }
        let width = max(1, viewport.width - 32) / page.width
        let height = max(1, viewport.height - 32) / page.height
        return clamp(mode == .fitWidth ? width : min(width, height))
    }
    static func normalizedCenter(_ visible: CGRect, page: CGSize) -> CGPoint {
        guard valid(page) else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: visible.midX / page.width, y: visible.midY / page.height)
    }
    static func center(_ normalized: CGPoint, page: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * page.width, y: normalized.y * page.height)
    }
}

struct PreviewZoomControls: View {
    @ObservedObject var zoom: PreviewZoomState
    private var percentages: [Int] {
        Array(Set([25, 50, 75, 100, 150, 200, 400, 800, Int((zoom.scale * 100).rounded())])).sorted()
    }
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { fitButtons; scaleControls }
                .fixedSize(horizontal: true, vertical: false)
            HStack(spacing: 10) {
                Menu {
                    Button("Einpassen") { zoom.fitPage() }
                    Button("Seitenbreite") { zoom.fitWidth() }
                } label: { Label("Ansicht", systemImage: "arrow.up.left.and.arrow.down.right") }
                scaleControls
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 8) { fitButtons; scaleControls }
        }
        .controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vergrößerung der Vorschau")
    }
    private var fitButtons: some View {
        HStack(spacing: 8) {
            Button("Einpassen") { zoom.fitPage() }.help("Ganze Seite einpassen (⌘0)")
            Button("Seitenbreite") { zoom.fitWidth() }.help("Seitenbreite einpassen (⌘2)")
        }
    }
    private var scaleControls: some View {
        HStack(spacing: 8) {
            Button { zoom.zoomOut() } label: { Label("Verkleinern", systemImage: "minus.magnifyingglass") }
                .labelStyle(.iconOnly).disabled(zoom.scale <= PreviewZoomGeometry.minimum)
                .help("Verkleinern (⌘−)")
            Picker("Vergrößerung", selection: Binding(
                get: { Int((zoom.scale * 100).rounded()) },
                set: { zoom.setScale(CGFloat($0) / 100) })) {
                ForEach(percentages, id: \.self) { Text("\($0) %").tag($0) }
            }
            .labelsHidden().frame(minWidth: 82, idealWidth: 94, maxWidth: 110)
            .help("100 % entspricht der Dokumentgröße bei der Scanauflösung (⌘1).")
            Button { zoom.zoomIn() } label: { Label("Vergrößern", systemImage: "plus.magnifyingglass") }
                .labelStyle(.iconOnly).disabled(zoom.scale >= PreviewZoomGeometry.maximum)
                .help("Vergrößern (⌘+)")
        }
    }
}

struct PreviewZoomCommands: Commands {
    @FocusedObject private var zoom: PreviewZoomState?
    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Group {
                Button("Vergrößern") { zoom?.zoomIn() }.keyboardShortcut("+")
                Button("Verkleinern") { zoom?.zoomOut() }.keyboardShortcut("-")
                Divider()
                Button("Einpassen") { zoom?.fitPage() }.keyboardShortcut("0")
                Button("Originalgröße (100 %)") { zoom?.setScale(1) }.keyboardShortcut("1")
                Button("Seitenbreite") { zoom?.fitWidth() }.keyboardShortcut("2")
            }.disabled(zoom == nil)
        }
    }
}
