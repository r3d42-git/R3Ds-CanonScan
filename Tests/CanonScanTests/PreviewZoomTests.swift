import AppKit
import XCTest
@testable import CanonScan

final class PreviewZoomTests: XCTestCase {
    @MainActor func testOversizedInvalidationCannotPaintWhiteOutsidePaper() throws {
        let canvas = PreviewImageCanvas(frame: CGRect(x: 0, y: 0, width: 100, height: 120))
        XCTAssertTrue(canvas.clipsToBounds)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 240, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.setFillColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1)
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
        graphics.cgContext.translateBy(x: 50, y: 50)
        // Reproduce AppKit's invalidation extending outside a centered page.
        canvas.draw(CGRect(x: -50, y: -50, width: 240, height: 240))
        let outside = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        let inside = try XCTUnwrap(bitmap.colorAt(x: 90, y: 100)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(outside.redComponent, 0.25, accuracy: 0.01)
        XCTAssertEqual(inside.redComponent, 1, accuracy: 0.01)
    }

    func testPhysical100PercentAt300And600DPIAndRotatedPixels() {
        let a = PreviewZoomGeometry.pointSize(rotatedPixels: CGSize(width: 2550, height: 3300), dpi: 300)
        let b = PreviewZoomGeometry.pointSize(rotatedPixels: CGSize(width: 5100, height: 6600), dpi: 600)
        XCTAssertEqual(a, CGSize(width: 612, height: 792))
        XCTAssertEqual(a, b)
        XCTAssertEqual(PreviewZoomGeometry.pointSize(rotatedPixels: CGSize(width: 3300, height: 2550), dpi: 300), CGSize(width: 792, height: 612))
    }
    func testFitsAndResizingVersusCustom() {
        let page = CGSize(width: 600, height: 800)
        let viewport = CGSize(width: 632, height: 432)
        XCTAssertEqual(PreviewZoomGeometry.scale(mode: .fitPage, custom: 3, page: page, viewport: viewport), 0.5)
        XCTAssertEqual(PreviewZoomGeometry.scale(mode: .fitWidth, custom: 3, page: page, viewport: viewport), 1)
        XCTAssertEqual(PreviewZoomGeometry.scale(mode: .fitPage, custom: 3, page: page, viewport: CGSize(width: 1232, height: 1632)), 2)
        XCTAssertEqual(PreviewZoomGeometry.scale(mode: .custom, custom: 3, page: page, viewport: viewport), 3)
        XCTAssertEqual(PreviewZoomGeometry.scale(mode: .custom, custom: 3, page: page, viewport: CGSize(width: 1232, height: 1632)), 3)
    }
    func testInvalidSizesAndClamping() {
        XCTAssertEqual(PreviewZoomGeometry.clamp(.nan), 1)
        XCTAssertEqual(PreviewZoomGeometry.clamp(.infinity), 1)
        XCTAssertEqual(PreviewZoomGeometry.clamp(0), 0.1)
        XCTAssertEqual(PreviewZoomGeometry.clamp(12), 8)
        XCTAssertEqual(PreviewZoomGeometry.scale(mode: .fitPage, custom: 2, page: .zero, viewport: .zero), 1)
        XCTAssertEqual(PreviewZoomGeometry.scale(mode: .fitWidth, custom: 2, page: CGSize(width: CGFloat.infinity, height: 20), viewport: CGSize(width: 100, height: 100)), 1)
    }
    @MainActor func testStateFitFeedbackCannotOverwriteCustomScale() {
        let state = PreviewZoomState()
        state.setScale(2.75)
        state.reportFitScale(0.5, mode: .fitPage)
        XCTAssertEqual(state.scale, 2.75)
        XCTAssertEqual(state.mode, .custom)
        state.fitWidth()
        state.reportFitScale(1.25, mode: .fitWidth)
        XCTAssertEqual(state.scale, 1.25)
        state.zoomIn()
        XCTAssertEqual(state.scale, 1.5625)
        XCTAssertEqual(state.mode, .custom)
    }
    @MainActor func testSamePageImageReplacementPreservesExactZoomAndViewport() {
        let scroll = PreviewScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let size = CGSize(width: 612, height: 792)
        let id = UUID()
        func loaded() -> LoadedPagePreview { LoadedPagePreview(image: NSImage(size: size), pageID: id, pointSize: size) }
        scroll.configure(loaded: loaded(), mode: .custom, scale: 3)
        scroll.contentView.scroll(to: CGPoint(x: 125, y: 244))
        let before = scroll.contentView.bounds
        let normalized = PreviewZoomGeometry.normalizedCenter(before, page: size)
        scroll.configure(loaded: loaded(), mode: .custom, scale: 3)
        XCTAssertEqual(scroll.magnification, 3)
        XCTAssertEqual(scroll.contentView.bounds, before)
        XCTAssertEqual(PreviewZoomGeometry.normalizedCenter(scroll.contentView.bounds, page: size), normalized)
        let restored = PreviewZoomGeometry.center(normalized, page: size)
        XCTAssertEqual(restored.x, before.midX, accuracy: 0.000001)
        XCTAssertEqual(restored.y, before.midY, accuracy: 0.000001)
    }
    @MainActor func testNativeFitRespondsToResizeWhileCustomStaysFixed() {
        let scroll = PreviewScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let size = CGSize(width: 612, height: 792)
        let page = LoadedPagePreview(image: NSImage(size: size), pageID: UUID(), pointSize: size)
        scroll.configure(loaded: page, mode: .fitPage, scale: 1)
        let first = scroll.magnification
        scroll.setFrameSize(CGSize(width: 800, height: 600)); scroll.layout()
        XCTAssertGreaterThan(scroll.magnification, first)
        scroll.configure(loaded: page, mode: .custom, scale: 2.5)
        scroll.setFrameSize(CGSize(width: 500, height: 400)); scroll.layout()
        XCTAssertEqual(scroll.magnification, 2.5)
    }
    @MainActor func testChangingPageKeepsCustomZoomAndResetsToTop() {
        let scroll = PreviewScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let size = CGSize(width: 612, height: 792)
        scroll.configure(loaded: LoadedPagePreview(image: NSImage(size: size), pageID: UUID(), pointSize: size), mode: .custom, scale: 2)
        scroll.contentView.scroll(to: CGPoint(x: 100, y: 350))
        scroll.configure(loaded: LoadedPagePreview(image: NSImage(size: size), pageID: UUID(), pointSize: size), mode: .custom, scale: 2)
        XCTAssertEqual(scroll.magnification, 2)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0)
    }

    @MainActor func testZoomFromCenteredFitKeepsPageCenterWhenScrollbarsAppear() {
        let scroll = PreviewScrollView(frame: CGRect(x: 0, y: 0, width: 548, height: 300))
        let size = CGSize(width: 595.2, height: 841.92)
        let page = LoadedPagePreview(image: NSImage(size: size), pageID: UUID(), pointSize: size)
        scroll.configure(loaded: page, mode: .fitPage, scale: 1)
        let initial = PreviewZoomGeometry.normalizedCenter(scroll.contentView.bounds, page: size)
        XCTAssertEqual(initial.x, 0.5, accuracy: 0.0001)
        XCTAssertEqual(initial.y, 0.5, accuracy: 0.0001)
        scroll.layout()
        let center = PreviewZoomGeometry.normalizedCenter(scroll.contentView.bounds, page: size)
        scroll.configure(loaded: page, mode: .custom, scale: scroll.magnification * 1.25)
        let enlarged = PreviewZoomGeometry.normalizedCenter(scroll.contentView.bounds, page: size)
        XCTAssertEqual(enlarged.x, center.x, accuracy: 0.0001)
        XCTAssertEqual(enlarged.y, center.y, accuracy: 0.0001)
        scroll.configure(loaded: page, mode: .custom, scale: 2)
        let further = PreviewZoomGeometry.normalizedCenter(scroll.contentView.bounds, page: size)
        XCTAssertEqual(further.x, center.x, accuracy: 0.0001)
        XCTAssertEqual(further.y, center.y, accuracy: 0.0001)
    }
}
