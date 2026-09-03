import Foundation
import Accelerate

public enum Resampler {

    /// Scales to fit `maxLongEdge` using vImage's high-quality path, which is a Lanczos
    /// resampler (`kvImageHighQualityResampling`). Returns the image untouched when it is
    /// already small enough.
    public static func fit(_ image: PixelImage, maxLongEdge: Int) throws -> PixelImage {
        guard maxLongEdge > 0, image.longEdge > maxLongEdge else { return image }
        let ratio = Double(maxLongEdge) / Double(image.longEdge)
        let outW = max(1, Int((Double(image.width) * ratio).rounded()))
        let outH = max(1, Int((Double(image.height) * ratio).rounded()))
        return try scale(image, toWidth: outW, height: outH)
    }

    public static func scale(_ image: PixelImage, toWidth outW: Int, height outH: Int) throws -> PixelImage {
        var dest = [UInt8](repeating: 0, count: outW * outH * 4)
        var source = image.rgba

        let error: vImage_Error = source.withUnsafeMutableBufferPointer { src in
            dest.withUnsafeMutableBufferPointer { dst in
                var srcBuffer = vImage_Buffer(data: src.baseAddress,
                                              height: vImagePixelCount(image.height),
                                              width: vImagePixelCount(image.width),
                                              rowBytes: image.bytesPerRow)
                var dstBuffer = vImage_Buffer(data: dst.baseAddress,
                                              height: vImagePixelCount(outH),
                                              width: vImagePixelCount(outW),
                                              rowBytes: outW * 4)
                return vImageScale_ARGB8888(&srcBuffer, &dstBuffer, nil,
                                            vImage_Flags(kvImageHighQualityResampling))
            }
        }
        guard error == kvImageNoError else {
            throw SquishError.io("resampling failed (vImage error \(error))")
        }
        return PixelImage(width: outW, height: outH, rgba: dest,
                          hasAlpha: image.hasAlpha, iccProfile: image.iccProfile)
    }
}
