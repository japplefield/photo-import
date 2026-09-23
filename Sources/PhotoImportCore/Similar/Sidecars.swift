import AVFoundation
import Foundation
import ImageIO

/// Files that belong to a photo and should be removed with it: its edit files (.AAE) and its Live Photo video.
/// Deliberately conservative: when ownership is ambiguous, the file is left alone.
public enum Sidecars {
    public static func find(for photo: URL) async -> [URL] {
        let dir = photo.deletingLastPathComponent()
        let stem = photo.deletingPathExtension().lastPathComponent
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let byLower = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        func existing(_ name: String) -> URL? { byLower[name.lowercased()].map { dir.appendingPathComponent($0) } }

        var found: [URL] = []

        // Edit files are matched by name. If another photo shares this stem (e.g. IMG_1.HEIC and IMG_1.JPG),
        // we can't tell whose edits they are, so skip them.
        let otherPhotoSameStem = names.contains {
            let u = dir.appendingPathComponent($0)
            return $0 != photo.lastPathComponent && CaptureDate.isImage(u)
                && u.deletingPathExtension().lastPathComponent.lowercased() == stem.lowercased()
        }
        if !otherPhotoSameStem {
            var aaeStems = [stem]
            if stem.hasPrefix("IMG_") { aaeStems.append("IMG_O" + stem.dropFirst(4)) }
            found += aaeStems.compactMap { existing("\($0).AAE") }
        }

        // Live Photo video: only when its content identifier matches the photo's, so a separate video that
        // happens to share the name is never touched.
        if let video = existing("\(stem).MOV"), let id = photoLiveID(photo), await videoLiveID(video) == id {
            found.append(video)
        }
        return found
    }

    static func photoLiveID(_ url: URL) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let apple = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] else { return nil }
        return apple["17"] as? String
    }

    static func videoLiveID(_ url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return nil }
        for item in items where item.identifier == .quickTimeMetadataContentIdentifier {
            return try? await item.load(.stringValue)
        }
        return nil
    }
}

public enum LibraryCleanup {
    public struct Result: Sendable {
        public var photos: [URL] = []
        public var sidecars: [URL] = []
        public var failures: [(URL, String)] = []
    }

    /// Moves each photo and its sidecars to the Trash (recoverable). `trash` is injectable for tests.
    public static func moveToTrash(_ photos: [URL],
                                   trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) async -> Result {
        var result = Result()
        for photo in photos {
            let extras = await Sidecars.find(for: photo)
            do {
                try trash(photo)
                result.photos.append(photo)
            } catch {
                result.failures.append((photo, error.localizedDescription))
                continue  // keep the sidecars if the photo itself stayed
            }
            for extra in extras {
                do {
                    try trash(extra)
                    result.sidecars.append(extra)
                } catch {
                    result.failures.append((extra, error.localizedDescription))
                }
            }
        }
        return result
    }
}
