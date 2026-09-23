import Foundation

/// Capture dates of every image in the library, cached in `.photoimport-dates.json` so rescans are fast.
public final class PhotoDateIndex {
    struct Entry: Codable {
        var size: Int64
        var mtime: Double
        var taken: Double
    }

    static let fileName = ".photoimport-dates.json"

    public let root: URL
    private var entries: [String: Entry] = [:]

    public init(root: URL) {
        self.root = root.resolvingSymlinksInPath()
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    private var cacheURL: URL { root.appendingPathComponent(Self.fileName) }

    /// All images in the library with their capture time (falls back to the file's modified time).
    public func scan(progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }) -> [PhotoRef] {
        let files = LibraryFiles.list(root, where: CaptureDate.isImage)
        var fresh: [String: Entry] = [:]
        var refs: [PhotoRef] = []
        for (i, file) in files.enumerated() {
            let attrs = (try? FileManager.default.attributesOfItem(atPath: file.url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let entry: Entry
            if let old = entries[file.rel], old.size == size, old.mtime == mtime {
                entry = old
            } else {
                let taken = CaptureDate.imageDate(file.url)?.timeIntervalSince1970 ?? mtime
                entry = Entry(size: size, mtime: mtime, taken: taken)
            }
            fresh[file.rel] = entry
            refs.append(PhotoRef(path: file.rel, taken: Date(timeIntervalSince1970: entry.taken)))
            progress(i + 1, files.count)
        }
        entries = fresh
        try? JSONEncoder().encode(entries).write(to: cacheURL, options: .atomic)
        return refs
    }
}
