import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Raw quality signals for one photo. `Recommender` turns a group of these into a pick.
public struct PhotoScore: Equatable, Sendable {
    /// Crispness of the sharpest part of the frame (Laplacian variance). Only meaningful relative to other photos.
    public var sharpness: Double
    /// Faces big enough to matter (not tiny background people).
    public var faces: Int
    public var facesWithEyesOpen: Int
    /// Vision's face capture quality, 0–1, averaged over faces (accounts for blur, expression, lighting).
    public var faceQuality: Double?
    /// Horizon tilt in degrees; nil when there's no clear horizon.
    public var tiltDegrees: Double?
    /// Vision's overall aesthetics score, -1…1.
    public var aesthetics: Double?

    public init(sharpness: Double, faces: Int = 0, facesWithEyesOpen: Int = 0,
                faceQuality: Double? = nil, tiltDegrees: Double? = nil, aesthetics: Double? = nil) {
        self.sharpness = sharpness
        self.faces = faces
        self.facesWithEyesOpen = facesWithEyesOpen
        self.faceQuality = faceQuality
        self.tiltDegrees = tiltDegrees
        self.aesthetics = aesthetics
    }
}

public enum PhotoScorer {
    public enum ScoreError: Error { case unreadable }

    /// Minimum face height, as a fraction of the image, for a face to count.
    static let minFaceHeight: CGFloat = 0.06
    /// Eye height ÷ width below this counts as closed.
    static let eyeOpenThreshold = 0.18

    /// Orientation-corrected, downscaled image (fast even for HEIC and RAW, which carry embedded previews).
    public static func loadImage(_ url: URL, maxPixel: Int = 1600) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    public static func score(url: URL) throws -> PhotoScore {
        guard let image = loadImage(url) else { throw ScoreError.unreadable }
        return try score(image: image)
    }

    public static func score(image: CGImage) throws -> PhotoScore {
        var score = PhotoScore(sharpness: sharpness(of: image))
        let landmarks = VNDetectFaceLandmarksRequest()
        let quality = VNDetectFaceCaptureQualityRequest()
        let horizon = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([landmarks, quality, horizon])

        let size = CGSize(width: image.width, height: image.height)
        let faces = (landmarks.results ?? []).filter { $0.boundingBox.height >= minFaceHeight }
        score.faces = faces.count
        score.facesWithEyesOpen = faces.filter { eyesOpen($0, imageSize: size) }.count

        let qualities = (quality.results ?? [])
            .filter { $0.boundingBox.height >= minFaceHeight }
            .compactMap { $0.faceCaptureQuality }
            .map(Double.init)
        score.faceQuality = qualities.isEmpty ? nil : qualities.reduce(0, +) / Double(qualities.count)

        if let h = horizon.results?.first { score.tiltDegrees = Double(h.angle) * 180 / .pi }

        // Separate so a failure here (e.g. unsupported hardware) doesn't lose the other signals.
        let aesthetics = VNCalculateImageAestheticsScoresRequest()
        if (try? handler.perform([aesthetics])) != nil, let a = aesthetics.results?.first {
            score.aesthetics = Double(a.overallScore)
        }
        return score
    }

    static func eyesOpen(_ face: VNFaceObservation, imageSize: CGSize) -> Bool {
        // If Vision can't find the eyes (profile, sunglasses), don't penalize the photo.
        guard let left = face.landmarks?.leftEye, let right = face.landmarks?.rightEye else { return true }
        return openness(left, imageSize) >= eyeOpenThreshold && openness(right, imageSize) >= eyeOpenThreshold
    }

    /// Eye height ÷ width, in image pixels.
    static func openness(_ eye: VNFaceLandmarkRegion2D, _ imageSize: CGSize) -> Double {
        let points = eye.pointsInImage(imageSize: imageSize)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(), maxX > minX else { return 1 }
        return Double((maxY - minY) / (maxX - minX))
    }

    /// Laplacian variance of the sharpest regions of a 512px grayscale copy. Using the best tiles (rather than
    /// the whole frame) means a sharp subject against a soft background still scores as sharp.
    static func sharpness(of image: CGImage) -> Double {
        let width = 512
        let height = max(8, Int(Double(image.height) * Double(width) / Double(max(image.width, 1))))
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }

        let tiles = 4
        var sums = [Double](repeating: 0, count: tiles * tiles)
        var squares = [Double](repeating: 0, count: tiles * tiles)
        var counts = [Double](repeating: 0, count: tiles * tiles)
        for y in 1..<(height - 1) {
            let ty = min(tiles - 1, y * tiles / height)
            for x in 1..<(width - 1) {
                let i = y * width + x
                let lap = 4 * Double(pixels[i]) - Double(pixels[i - 1]) - Double(pixels[i + 1])
                    - Double(pixels[i - width]) - Double(pixels[i + width])
                let t = ty * tiles + min(tiles - 1, x * tiles / width)
                sums[t] += lap
                squares[t] += lap * lap
                counts[t] += 1
            }
        }
        let variances = (0..<(tiles * tiles)).map { t -> Double in
            guard counts[t] > 0 else { return 0 }
            let mean = sums[t] / counts[t]
            return squares[t] / counts[t] - mean * mean
        }.sorted(by: >)
        return variances.prefix(3).reduce(0, +) / 3
    }
}
