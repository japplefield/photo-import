import AppKit
import QuickLookThumbnailing
import PhotoImportCore
import SwiftUI

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL, maxPixel: Int) async -> NSImage? {
        let key = "\(url.path)#\(maxPixel)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var image = await Task.detached(priority: .utility) {
            PhotoScorer.loadImage(url, maxPixel: maxPixel).map { NSImage(cgImage: $0, size: .zero) }
        }.value
        if image == nil {
            // Videos and other non-image files.
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: maxPixel, height: maxPixel),
                                                       scale: 1, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

struct ThumbnailView: View {
    let url: URL
    let maxPixel: Int
    /// Fill crops to the frame (list rows); fit shows the whole photo so framing can be judged (grid).
    var fill = false
    var background: Color = .secondary.opacity(0.12)
    @State private var image: NSImage?

    var body: some View {
        background
            .overlay {
                if let image {
                    if fill {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(nsImage: image).resizable().scaledToFit()
                    }
                }
            }
            .clipped()
            .task(id: url) { image = await ThumbnailCache.shared.image(for: url, maxPixel: maxPixel) }
    }
}
