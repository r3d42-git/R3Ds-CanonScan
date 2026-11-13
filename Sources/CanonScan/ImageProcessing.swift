import CoreGraphics
import Foundation

/// A white, reversible mask in original (unrotated) scanner coordinates.
/// Distances are measured from the corresponding top or bottom edge.
struct ScannerEdgeCorrection: Sendable {
    struct Line: Sendable {
        let intercept: Double
        let slope: Double
        let padding: Double
        func depth(at x: Double) -> Double { intercept + slope * x + padding }
    }
    let originalWidth: Int
    let originalHeight: Int
    let top: Line?
    let bottom: Line?
}

struct ScannerEdgeCleaner {
    /// Detect only narrow, nearly continuous dark edges within the outer 8 mm.
    /// A normal printed frame 12 mm inside the page is outside this search area.
    static func detect(in image: CGImage, dpi: Double) -> ScannerEdgeCorrection? {
        guard dpi > 0, image.width >= 100, image.height >= 100 else { return nil }
        let depth = min(Int((dpi * 8 / 25.4).rounded(.down)), image.height / 4)
        guard depth >= 3 else { return nil }
        let top = detectLine(in: image, depth: depth, bottom: false, dpi: dpi)
            ?? detectClippedLine(in: image, depth: depth, bottom: false, dpi: dpi)
        let bottom = detectLine(in: image, depth: depth, bottom: true, dpi: dpi)
            ?? detectClippedLine(in: image, depth: depth, bottom: true, dpi: dpi)
        guard top != nil || bottom != nil else { return nil }
        return ScannerEdgeCorrection(originalWidth: image.width, originalHeight: image.height, top: top, bottom: bottom)
    }

    private static func detectLine(in image: CGImage, depth: Int, bottom: Bool, dpi: Double) -> ScannerEdgeCorrection.Line? {
        let width = image.width
        let cropY = bottom ? image.height - depth : 0
        guard let strip = image.cropping(to: CGRect(x: 0, y: cropY, width: width, height: depth)),
              let context = bitmap(strip), let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = context.bytesPerRow
        let left = Int((Double(width) * 0.02).rounded(.up)), right = Int((Double(width) * 0.98).rounded(.down))
        guard right > left else { return nil }
        func gray(_ x: Int, _ d: Int) -> Int {
            let y = bottom ? depth - 1 - d : d
            let offset = y * stride + x * 4
            return (Int(data[offset]) * 77 + Int(data[offset + 1]) * 150 + Int(data[offset + 2]) * 29) >> 8
        }
        // One darkest candidate per column. Missing columns count against confidence.
        var candidates: [(x: Int, y: Int)] = []
        for x in left..<right {
            var darkest = 150, position: Int?
            for d in 0..<depth {
                let value = gray(x, d)
                if value < darkest { darkest = value; position = d }
            }
            if let position { candidates.append((x, position)) }
        }
        let required = Int(ceil(Double(right - left) * 0.92))
        guard candidates.count >= required else { return nil }
        func median(_ values: [Int]) -> Double {
            let sorted = values.sorted()
            return Double(sorted[sorted.count / 2])
        }
        let quarter = max(1, candidates.count / 4)
        let first = Array(candidates.prefix(quarter)), last = Array(candidates.suffix(quarter))
        let x1 = median(first.map(\.x)), x2 = median(last.map(\.x))
        let y1 = median(first.map(\.y)), y2 = median(last.map(\.y))
        guard x2 > x1 else { return nil }
        let slope = (y2 - y1) / (x2 - x1), intercept = y1 - slope * x1
        guard abs(slope * Double(width - 1)) <= dpi * 3 / 25.4 else { return nil }
        let tolerance = max(1, Int((dpi * 0.25 / 25.4).rounded(.up)))
        let maxThickness = max(2, Int((dpi * 1.2 / 25.4).rounded(.up)))
        var matched = 0, deepestResidual = 0.0
        for x in left..<right {
            let predicted = intercept + slope * Double(x)
            let low = max(0, Int(predicted.rounded()) - tolerance), high = min(depth - 1, Int(predicted.rounded()) + tolerance)
            guard low <= high else { continue }
            var darkest = 150, position: Int?
            for d in low...high {
                let value = gray(x, d)
                if value < darkest { darkest = value; position = d }
            }
            guard let position else { continue }
            var start = position, end = position
            while start > 0 && gray(x, start - 1) < 150 { start -= 1 }
            while end + 1 < depth && gray(x, end + 1) < 150 { end += 1 }
            guard end - start + 1 <= maxThickness else { continue }
            // A line that continues past the search strip cannot safely be classified.
            guard end < depth - 1 else { continue }
            matched += 1
            deepestResidual = max(deepestResidual, Double(end) - predicted)
        }
        guard matched >= required else { return nil }
        let padding = deepestResidual + 2
        // Never mask beyond the approved 8 mm search strip, even at the outer corners.
        guard intercept + padding >= 0, intercept + slope * Double(width - 1) + padding >= 0,
              max(intercept, intercept + slope * Double(width - 1)) + padding <= Double(depth) else { return nil }
        return ScannerEdgeCorrection.Line(intercept: intercept, slope: slope, padding: padding)
    }

    /// A skewed scanner edge can leave the image before crossing the full width.
    /// Keep this separate from the strict detector: an ordinary partial line must
    /// not qualify unless its fitted boundary actually crosses the outer image boundary.
    private static func detectClippedLine(in image: CGImage, depth: Int, bottom: Bool, dpi: Double) -> ScannerEdgeCorrection.Line? {
        let width = image.width
        let cropY = bottom ? image.height - depth : 0
        guard let strip = image.cropping(to: CGRect(x: 0, y: cropY, width: width, height: depth)),
              let context = bitmap(strip), let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let stride = context.bytesPerRow
        let left = Int((Double(width) * 0.02).rounded(.up)), right = Int((Double(width) * 0.98).rounded(.down))
        guard right > left else { return nil }
        let tolerance = dpi * 0.25 / 25.4
        let maxThickness = max(1, Int((dpi * 1.2 / 25.4).rounded(.down)))
        func gray(_ x: Int, _ d: Int) -> Int {
            let y = bottom ? depth - 1 - d : d
            let offset = y * stride + x * 4
            return (Int(data[offset]) * 77 + Int(data[offset + 1]) * 150 + Int(data[offset + 2]) * 29) >> 8
        }
        func run(at x: Int, position: Int) -> (start: Int, end: Int)? {
            var start = position, end = position
            while start > 0 && gray(x, start - 1) < 150 { start -= 1 }
            while end + 1 < depth && gray(x, end + 1) < 150 { end += 1 }
            guard end < depth - 1, end - start + 1 <= maxThickness else { return nil }
            return (start, end)
        }
        // Fit the inward edge of each narrow dark run. Its deepest point remains
        // measurable after the darkest centre has already been clipped at depth 0.
        var candidates: [(x: Int, y: Int)] = []
        for x in left..<right {
            var darkest = 150, position: Int?
            for d in 0..<depth where gray(x, d) < darkest { darkest = gray(x, d); position = d }
            if let position, let edge = run(at: x, position: position) { candidates.append((x, edge.end)) }
        }
        guard candidates.count >= Int(ceil(Double(right - left) * 0.4)) else { return nil }
        // Values pinned to the image boundary cannot establish the line's slope.
        let fitting = candidates.filter { Double($0.y) > tolerance }
        guard fitting.count >= 4 else { return nil }
        func median(_ values: [Int]) -> Double {
            let sorted = values.sorted(); return Double(sorted[sorted.count / 2])
        }
        let quarter = max(1, fitting.count / 4)
        let first = Array(fitting.prefix(quarter)), last = Array(fitting.suffix(quarter))
        let x1 = median(first.map(\.x)), x2 = median(last.map(\.x))
        let y1 = median(first.map(\.y)), y2 = median(last.map(\.y))
        guard x2 > x1 else { return nil }
        let slope = (y2 - y1) / (x2 - x1), intercept = y1 - slope * x1
        let startDepth = intercept, endDepth = intercept + slope * Double(width - 1)
        let maxVisibleDepth = dpi * 3 / 25.4
        let exitsRight = startDepth >= 0 && startDepth <= maxVisibleDepth && endDepth < -tolerance && slope < 0
        let exitsLeft = endDepth >= 0 && endDepth <= maxVisibleDepth && startDepth < -tolerance && slope > 0
        guard exitsRight != exitsLeft else { return nil }

        var visible = 0, matched = 0, deepestResidual = 0.0
        for x in left..<right {
            let predicted = intercept + slope * Double(x)
            // Confidence is measured only over the geometrically visible region,
            // with no tolerance-expanded inclusion of columns beyond the boundary.
            guard predicted >= 0, predicted < Double(depth) else { continue }
            visible += 1
            let low = max(0, Int(ceil(predicted - tolerance)))
            let high = min(depth - 1, Int(floor(predicted + tolerance)))
            guard low <= high else { continue }
            var darkest = 150, position: Int?
            for d in low...high where gray(x, d) < darkest { darkest = gray(x, d); position = d }
            guard let position, let edge = run(at: x, position: position),
                  abs(Double(edge.end) - predicted) <= tolerance else { continue }
            matched += 1
            deepestResidual = max(deepestResidual, Double(edge.end) - predicted)
        }
        guard visible >= Int(ceil(Double(right - left) * 0.4)),
              matched >= Int(ceil(Double(visible) * 0.92)) else { return nil }
        let padding = deepestResidual + 2
        guard max(startDepth, endDepth) + padding <= Double(depth) else { return nil }
        return ScannerEdgeCorrection.Line(intercept: intercept, slope: slope, padding: padding)
    }

    /// Applies a previously detected original-pixel mask to either a full image or
    /// a proportional thumbnail. It never changes pixel dimensions or writes a file.
    static func apply(_ correction: ScannerEdgeCorrection?, to image: CGImage) -> CGImage {
        let grayscale = image.colorSpace?.model == .monochrome
        let bytesPerPixel = grayscale ? 1 : 4
        guard let correction, let context = bitmap(image, grayscale: grayscale),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return image }
        let xScale = Double(image.width) / Double(correction.originalWidth)
        let yScale = Double(image.height) / Double(correction.originalHeight)
        for x in 0..<image.width {
            let originalX = Double(x) / xScale
            if let line = correction.top {
                let end = min(image.height, max(0, Int(ceil(line.depth(at: originalX) * yScale))))
                for y in 0..<end { whiten(data, offset: y * context.bytesPerRow + x * bytesPerPixel, bytesPerPixel: bytesPerPixel) }
            }
            if let line = correction.bottom {
                let count = min(image.height, max(0, Int(ceil(line.depth(at: originalX) * yScale))))
                for y in (image.height - count)..<image.height { whiten(data, offset: y * context.bytesPerRow + x * bytesPerPixel, bytesPerPixel: bytesPerPixel) }
            }
        }
        return context.makeImage() ?? image
    }

    static func clean(_ image: CGImage, dpi: Double, enabled: Bool) -> CGImage {
        guard enabled else { return image }
        return apply(detect(in: image, dpi: dpi), to: image)
    }

    private static func whiten(_ data: UnsafeMutablePointer<UInt8>, offset: Int, bytesPerPixel: Int) {
        for channel in 0..<bytesPerPixel { data[offset + channel] = 255 }
    }
    private static func bitmap(_ image: CGImage, grayscale: Bool = false) -> CGContext? {
        let info = grayscale ? CGImageAlphaInfo.none.rawValue : CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * (grayscale ? 1 : 4),
                                      space: grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context
    }
}
