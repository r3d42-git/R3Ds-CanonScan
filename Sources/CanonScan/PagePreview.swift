import AppKit
import SwiftUI

struct LoadedPagePreview {
    let image: NSImage
    let pageID: UUID
    let pointSize: CGSize
}

struct PagePreview: View {
    let page: ScanPage
    @ObservedObject var zoom: PreviewZoomState
    @State private var loaded: LoadedPagePreview?
    @State private var loading = false
    @State private var failure: String?
    @State private var retry = 0
    private var requestID: String {
        "\(page.id):\(page.imageURL.path):\(page.rotation):\(page.dpi):\(page.cleanScannerEdges):\(page.appearance.rawValue):\(retry)"
    }
    var body: some View {
        VStack(spacing: 0) {
            PreviewZoomControls(zoom: zoom)
            NativePagePreview(loaded: loaded, zoom: zoom)
                .overlay(alignment: loaded == nil ? .center : .top) {
                    if let failure {
                        VStack(spacing: 8) {
                            Label("Vorschau konnte nicht geladen werden", systemImage: "exclamationmark.triangle")
                            Text(failure).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                            Button("Erneut versuchen") { retry += 1 }
                        }
                        .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(12)
                    } else if loading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Vorschau wird aufbereitet …").font(.callout)
                        }
                        .padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(12)
                        .allowsHitTesting(false)
                    }
                }
        }
        .task(id: requestID) {
            loading = true; failure = nil
            let snapshot = page
            let result = await Task.detached(priority: .userInitiated) {
                Result { try PageImage.load(snapshot) }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let image):
                let size = PreviewZoomGeometry.pointSize(rotatedPixels: CGSize(width: image.width, height: image.height), dpi: snapshot.dpi)
                loaded = LoadedPagePreview(image: NSImage(cgImage: image, size: size), pageID: snapshot.id, pointSize: size)
            case .failure(let error): failure = error.localizedDescription
            }
            loading = false
        }
    }
}

/// The AppKit boundary only owns scrolling and drawing; zoom intent belongs to SwiftUI.
struct NativePagePreview: NSViewRepresentable {
    let loaded: LoadedPagePreview?
    @ObservedObject var zoom: PreviewZoomState
    func makeNSView(context: Context) -> PreviewScrollView { PreviewScrollView() }
    func updateNSView(_ view: PreviewScrollView, context: Context) {
        view.onScale = { [weak zoom] scale, mode, isGesture in
            if isGesture { zoom?.setScale(scale) }
            else { zoom?.reportFitScale(scale, mode: mode) }
        }
        view.configure(loaded: loaded, mode: zoom.mode, scale: zoom.scale)
    }
    static func dismantleNSView(_ view: PreviewScrollView, coordinator: ()) {
        view.onScale = nil
        view.callbackGeneration += 1
    }
}

final class PreviewCenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if documentView.frame.width < result.width { result.origin.x = (documentView.frame.width - result.width) / 2 }
        if documentView.frame.height < result.height { result.origin.y = (documentView.frame.height - result.height) / 2 }
        return result
    }
}

final class PreviewImageCanvas: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // NSView no longer clips by default on macOS 14+. The invalidated
        // drawing region can extend far outside this small centered page.
        clipsToBounds = true
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
    }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        NSGraphicsContext.current?.imageInterpolation = .high
        image?.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }
}

final class PreviewScrollView: NSScrollView {
    let canvas = PreviewImageCanvas()
    private(set) var pageID: UUID?
    private var mode: PreviewZoomMode = .fitPage
    private var customScale: CGFloat = 1
    private var applying = false
    private var lastViewport = CGSize.zero
    var onScale: ((CGFloat, PreviewZoomMode, Bool) -> Void)?
    var callbackGeneration = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentView = PreviewCenteringClipView()
        documentView = canvas
        hasVerticalScroller = true; hasHorizontalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        drawsBackground = true; backgroundColor = .underPageBackgroundColor
        contentView.drawsBackground = true
        contentView.backgroundColor = .underPageBackgroundColor
        allowsMagnification = true
        minMagnification = PreviewZoomGeometry.minimum
        maxMagnification = PreviewZoomGeometry.maximum
        canvas.setAccessibilityElement(true)
        canvas.setAccessibilityLabel("Eingelesene Dokumentseite")
        canvas.setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(loaded: LoadedPagePreview?, mode: PreviewZoomMode, scale: CGFloat) {
        // Invalidate deferred notifications from an earlier SwiftUI intent.
        callbackGeneration += 1
        let intentChanged = self.mode != mode || (mode == .custom && abs(customScale - scale) > 0.0001)
        self.mode = mode; customScale = scale
        var pageChanged = false
        var sizeChanged = false
        var center = PreviewZoomGeometry.normalizedCenter(contentView.bounds, page: canvas.bounds.size)
        if let loaded {
            pageChanged = pageID != loaded.pageID
            sizeChanged = canvas.frame.size != loaded.pointSize
            pageID = loaded.pageID
            if canvas.image !== loaded.image { canvas.image = loaded.image }
            if sizeChanged { canvas.setFrameSize(loaded.pointSize) }
        }
        if pageChanged { center = CGPoint(x: 0.5, y: 0) }
        if intentChanged || sizeChanged || pageChanged {
            applyZoom(center: center)
            if pageChanged { scrollToTop() }
        } else if mode != .custom {
            report(magnification, gesture: false)
        }
    }

    override func layout() {
        super.layout()
        guard !applying, lastViewport != contentSize else { return }
        lastViewport = contentSize
        if mode != .custom { applyZoom() }
    }
    private func applyZoom(center normalized: CGPoint? = nil) {
        guard !applying, PreviewZoomGeometry.valid(canvas.bounds.size), PreviewZoomGeometry.valid(contentSize) else { return }
        applying = true
        let center = PreviewZoomGeometry.center(normalized ?? PreviewZoomGeometry.normalizedCenter(contentView.bounds, page: canvas.bounds.size), page: canvas.bounds.size)
        let desired = PreviewZoomGeometry.scale(mode: mode, custom: customScale, page: canvas.bounds.size, viewport: contentSize)
        if abs(magnification - desired) > 0.0001 { magnification = desired }
        // Re-anchor explicitly in document coordinates. AppKit's centeredAt
        // conversion can jump when the previously fitted page has negative
        // centered clip bounds and becomes larger than the viewport.
        var visible = contentView.bounds
        visible.origin = CGPoint(x: center.x - visible.width / 2, y: center.y - visible.height / 2)
        contentView.scroll(to: contentView.constrainBoundsRect(visible).origin)
        reflectScrolledClipView(contentView)
        applying = false
        report(desired, gesture: false)
    }
    private func scrollToTop() {
        var visible = contentView.bounds
        visible.origin.y = 0
        // A fitted short page must remain centered; only an overflowing page
        // should align its first row with the top of the viewport.
        contentView.scroll(to: contentView.constrainBoundsRect(visible).origin)
        reflectScrolledClipView(contentView)
    }
    override func magnify(with event: NSEvent) {
        // Native magnification can trigger layout before returning. Stop fitting
        // first so a pinch never gets reset by a fit-to-window layout pass.
        mode = .custom
        super.magnify(with: event)
        // Preserve native gesture anchoring. A gesture changes the intent to a fixed custom scale.
        customScale = magnification
        report(magnification, gesture: true)
    }
    private func report(_ value: CGFloat, gesture: Bool) {
        callbackGeneration += 1
        let generation = callbackGeneration, expectedMode = mode
        DispatchQueue.main.async { [weak self] in
            guard let self, self.callbackGeneration == generation else { return }
            self.onScale?(value, expectedMode, gesture)
        }
    }
}
