import AVFoundation
import Foundation
import ImageIO

/// When a photo or video was taken, read from the file itself (EXIF / QuickTime metadata).
public enum CaptureDate {
    public static let imageExtensions: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "png", "dng", "arw", "cr2", "cr3", "nef", "raf", "tif", "tiff", "webp", "gif",
    ]

    public static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    public static func read(from url: URL) async -> Date? {
        if let date = imageDate(url) { return date }
        return await movieDate(url)
    }

    /// EXIF DateTimeOriginal (with sub-seconds when present), interpreted as local wall-clock time.
    public static func imageDate(_ url: URL) -> Date? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let text: String?
        let subsec: String?
        if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            (text, subsec) = (s, exif[kCGImagePropertyExifSubsecTimeOriginal] as? String)
        } else if let s = exif[kCGImagePropertyExifDateTimeDigitized] as? String {
            (text, subsec) = (s, exif[kCGImagePropertyExifSubsecTimeDigitized] as? String)
        } else {
            (text, subsec) = (tiff[kCGImagePropertyTIFFDateTime] as? String, exif[kCGImagePropertyExifSubsecTime] as? String)
        }
        guard let text, let date = exifFormatter.date(from: text) else { return nil }
        if let subsec, let fraction = Double("0." + subsec.trimmingCharacters(in: .whitespaces)) {
            return date.addingTimeInterval(fraction)
        }
        return date
    }

    static func movieDate(_ url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        guard let item = try? await asset.load(.creationDate) else { return nil }
        return (try? await item.load(.dateValue)) ?? nil
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()
}
