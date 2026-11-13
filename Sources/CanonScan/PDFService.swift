import AppKit
import CoreText
import ImageIO
import PDFKit
import Vision

struct RecognizedLine: Sendable {
    let text: String
    /// Vision coordinates: normalized, origin at the bottom left.
    let bounds: CGRect
}

protocol TextRecognizing {
    func recognize(_ image: CGImage) throws -> [RecognizedLine]
}

struct LocalTextRecognizer: TextRecognizing {
    func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { result in
            guard let candidate = result.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, bounds: result.boundingBox)
        }
    }
}

enum PDFExportError: LocalizedError {
    case invalidImage(Int), creation, recognition(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidImage(let page): "Seite \(page) konnte nicht gelesen werden. Die Originaldateien bleiben erhalten."
        case .creation: "Die PDF-Datei konnte nicht erstellt werden."
        case .recognition(let page, _): "Die Texterkennung für Seite \(page) ist fehlgeschlagen. Du kannst es erneut versuchen oder die PDF ohne Textebene sichern."
        }
    }
}

struct PageImage {
    private final class CachedImage { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    private static let cache: NSCache<NSString, CachedImage> = {
        let value = NSCache<NSString, CachedImage>(); value.totalCostLimit = 192 * 1024 * 1024; return value
    }()
    private static let processingSlots = DispatchSemaphore(value: 2)

    static func load(_ page: ScanPage, maxPixelSize: Int? = nil) throws -> CGImage {
        let attributes = try? FileManager.default.attributesOfItem(atPath: page.imageURL.path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(page.imageURL.path):\(stamp):\(page.dpi):\(page.rotation):\(page.appearance.rawValue):\(page.cleanScannerEdges)" as NSString
        if let image = cache.object(forKey: key)?.image { return try thumbnail(image, maxPixelSize: maxPixelSize) }
        processingSlots.wait()
        defer { processingSlots.signal() }
        if let image = cache.object(forKey: key)?.image { return try thumbnail(image, maxPixelSize: maxPixelSize) }
        guard let source = CGImageSourceCreateWithURL(page.imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PDFExportError.invalidImage(0)
        }
        let edge = page.cleanScannerEdges && page.appearance != .original ? ScannerEdgeCleaner.detect(in: image, dpi: Double(page.dpi)) : nil
        let enhanced = try DocumentEnhancer.process(image, dpi: Double(page.dpi), appearance: page.appearance)
        let corrected = ScannerEdgeCleaner.apply(edge, to: enhanced)
        let result = try rotated(corrected, degrees: page.rotation)
        cache.setObject(CachedImage(result), forKey: key, cost: result.bytesPerRow * result.height)
        return try thumbnail(result, maxPixelSize: maxPixelSize)
    }

    private static func thumbnail(_ image: CGImage, maxPixelSize: Int?) throws -> CGImage {
        guard let maxPixelSize, maxPixelSize > 0, max(image.width, image.height) > maxPixelSize else { return image }
        let factor = Double(maxPixelSize) / Double(max(image.width, image.height))
        let width = max(1, Int((Double(image.width) * factor).rounded())), height = max(1, Int((Double(image.height) * factor).rounded()))
        let gray = image.colorSpace?.model == .monochrome
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PDFExportError.creation }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw PDFExportError.creation }; return result
    }
    static func rotated(_ image: CGImage, degrees: Int) throws -> CGImage {
        guard degrees != 0 else { return image }
        let swap = degrees % 180 != 0
        let width = swap ? image.height : image.width, height = swap ? image.width : image.height
        let gray = image.colorSpace?.model == .monochrome
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PDFExportError.creation
        }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        // The document action rotates clockwise on the page.
        context.rotate(by: -CGFloat(degrees) * .pi / 180)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                      width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let rotated = context.makeImage() else { throw PDFExportError.creation }
        return rotated
    }
}

struct PDFService {
    /// Image data is embedded losslessly by Core Graphics. OCR adds only invisible text.
    static func create(pages: [ScanPage], recognizeText: Bool, recognizer: TextRecognizing = LocalTextRecognizer(),
                       onProgress: (Int) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws -> Data {
        guard !pages.isEmpty, let data = CFDataCreateMutable(nil, 0),
              let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw PDFExportError.creation }
        for (index, page) in pages.enumerated() {
            if isCancelled() { context.closePDF(); throw CancellationError() }
            try autoreleasepool {
                let image: CGImage
                do { image = try PageImage.load(page) }
                catch { throw PDFExportError.invalidImage(index + 1) }
                var mediaBox = CGRect(origin: .zero, size: ScanPage.pointSize(pixelWidth: image.width, pixelHeight: image.height,
                                                                            dpi: page.dpi, rotation: 0))
                let box = NSData(bytes: &mediaBox, length: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
                context.interpolationQuality = .high
                context.draw(image, in: mediaBox)
                if recognizeText {
                    let lines: [RecognizedLine]
                    do { lines = try recognizer.recognize(image) }
                    catch { throw PDFExportError.recognition(index + 1, error.localizedDescription) }
                    for line in lines { drawInvisible(line, on: context, size: mediaBox.size) }
                }
                context.endPDFPage()
                onProgress(index + 1)
            }
        }
        context.closePDF()
        return data as Data
    }

    private static func drawInvisible(_ line: RecognizedLine, on context: CGContext, size: CGSize) {
        let rect = CGRect(x: line.bounds.minX * size.width, y: line.bounds.minY * size.height,
                          width: line.bounds.width * size.width, height: line.bounds.height * size.height)
        guard !line.text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        let attributed = NSAttributedString(string: line.text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
        guard width > 0, ascent + descent > 0 else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / width, y: rect.height / (ascent + descent))
        context.textPosition = CGPoint(x: 0, y: descent)
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }

    static func export(pages: [ScanPage], to destination: URL, recognizeText: Bool,
                       onProgress: (Int) -> Void = { _ in }, isCancelled: () -> Bool = { false }) throws {
        let data = try create(pages: pages, recognizeText: recognizeText, onProgress: onProgress, isCancelled: isCancelled)
        if isCancelled() { throw CancellationError() }
        try data.write(to: destination, options: .atomic)
    }
}
