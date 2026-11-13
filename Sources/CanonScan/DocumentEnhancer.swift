import Accelerate
import CoreGraphics
import Foundation

/// Document rendering only: the source pixels on disk are never modified.
enum DocumentEnhancer {
    static func process(_ image: CGImage, dpi: Double, appearance: PageAppearance) throws -> CGImage {
        guard appearance != .original else { return image }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw PDFExportError.creation }

        // A high percentile over each sensor column estimates paper white while
        // ignoring text and ordinary tables. It removes fixed vertical shading
        // without using a blur over document strokes or resampling the page.
        var white = [Double](repeating: 255, count: width)
        let step = max(1, height / 1400), sampleCount = (height + step - 1) / step
        pixels.withUnsafeBufferPointer { input in
            var histogram = [Int](repeating: 0, count: 256)
            for x in 0..<width {
                for value in 0..<256 { histogram[value] = 0 }
                for y in stride(from: 0, to: height, by: step) { histogram[Int(input[y * width + x])] += 1 }
                var sum = 0
                for value in 0..<256 {
                    sum += histogram[value]
                    if sum * 5 >= sampleCount * 4 { white[x] = Double(max(value, 225)); break }
                }
            }
        }
        let radius = max(1, min(width / 2, Int((dpi / 20).rounded())))
        var prefix = [Double](repeating: 0, count: width + 1)
        for x in 0..<width { prefix[x + 1] = prefix[x] + white[x] }
        var lookup = [UInt8](repeating: 0, count: width * 256)
        for x in 0..<width {
            let left = max(0, x - radius), right = min(width, x + radius + 1)
            let paper = (prefix[right] - prefix[left]) / Double(right - left)
            for value in 0..<256 {
                // Modest black-point correction and white roll-off suppress the
                // scanner's paper haze; gray ink remains gray rather than binary.
                let normalized = Double(max(0, value - 12)) * 255 * 255 / ((paper - 12) * 241)
                lookup[x * 256 + value] = UInt8(clamping: Int(normalized.rounded()))
            }
        }
        pixels.withUnsafeMutableBufferPointer { buffer in
            lookup.withUnsafeBufferPointer { table in
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width { buffer[row + x] = table[x * 256 + Int(buffer[row + x])] }
                }
            }
        }
        // A mild unsharp mask at the original resolution. Never resize text to
        // make it appear sharper and never smear it with a denoising blur.
        let kernel = UInt32(max(3, min(7, Int((dpi / 150).rounded()) | 1)))
        var blurred = [UInt8](repeating: 0, count: pixels.count)
        let blurStatus = pixels.withUnsafeMutableBytes { input in
            blurred.withUnsafeMutableBytes { output in
                var source = vImage_Buffer(data: input.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var target = vImage_Buffer(data: output.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                return vImageBoxConvolve_Planar8(&source, &target, nil, 0, 0, kernel, kernel, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        guard blurStatus == kvImageNoError else { throw PDFExportError.creation }
        pixels.withUnsafeMutableBufferPointer { output in
            blurred.withUnsafeBufferPointer { lowPass in
                for index in 0..<output.count {
                    let value = Int(output[index]), difference = value - Int(lowPass[index])
                    if abs(difference) > 3 { output[index] = UInt8(clamping: value + difference / 2) }
                }
            }
        }
        if appearance == .blackAndWhite { pixels = try adaptiveThreshold(pixels, width: width, height: height, dpi: dpi) }
        return try grayscaleImage(pixels, width: width, height: height)
    }

    private static func adaptiveThreshold(_ pixels: [UInt8], width: Int, height: Int, dpi: Double) throws -> [UInt8] {
        // Sauvola's threshold follows local luminance and contrast. A fixed
        // hardware threshold irreversibly loses light/thin character strokes.
        let kernel = UInt32(max(15, min(101, Int((dpi / 10).rounded()) | 1)))
        var values = [Float](repeating: 0, count: pixels.count)
        pixels.withUnsafeBufferPointer { input in
            values.withUnsafeMutableBufferPointer { output in vDSP_vfltu8(input.baseAddress!, 1, output.baseAddress!, 1, vDSP_Length(input.count)) }
        }
        var squared = [Float](repeating: 0, count: values.count)
        values.withUnsafeBufferPointer { input in
            squared.withUnsafeMutableBufferPointer { output in vDSP_vsq(input.baseAddress!, 1, output.baseAddress!, 1, vDSP_Length(input.count)) }
        }
        let mean = try boxMean(values, width: width, height: height, kernel: kernel)
        values.removeAll()
        let squareMean = try boxMean(squared, width: width, height: height, kernel: kernel)
        squared.removeAll()
        var output = [UInt8](repeating: 255, count: pixels.count)
        output.withUnsafeMutableBufferPointer { result in
            pixels.withUnsafeBufferPointer { input in
                mean.withUnsafeBufferPointer { average in
                    squareMean.withUnsafeBufferPointer { secondMoment in
                        for index in 0..<input.count {
                            let m = average[index]
                            let deviation = sqrt(max(0, secondMoment[index] - m * m))
                            let threshold = m * (1 + 0.13 * (deviation / 128 - 1))
                            result[index] = Float(input[index]) < threshold ? 0 : 255
                        }
                    }
                }
            }
        }
        return output
    }

    private static func boxMean(_ input: [Float], width: Int, height: Int, kernel: UInt32) throws -> [Float] {
        var sourceValues = input
        var output = [Float](repeating: 0, count: input.count)
        let weights = [Float](repeating: 1 / Float(kernel), count: Int(kernel))
        let status = sourceValues.withUnsafeMutableBytes { sourceBytes in
            output.withUnsafeMutableBytes { outputBytes in
                var source = vImage_Buffer(data: sourceBytes.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                var target = vImage_Buffer(data: outputBytes.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
                return weights.withUnsafeBufferPointer { coefficients in
                    vImageSepConvolve_PlanarF(&source, &target, nil, 0, 0,
                        coefficients.baseAddress!, kernel, coefficients.baseAddress!, kernel,
                        0, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        guard status == kvImageNoError else { throw PDFExportError.creation }
        return output
    }

    static func grayscaleImage(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw PDFExportError.creation }
        return image
    }
}
