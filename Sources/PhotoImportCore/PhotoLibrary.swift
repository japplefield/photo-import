import Foundation

/// The destination folder, plus a content-hash index of everything in it so duplicates are never copied twice.
/// The index is cached in `.photoimport-index.json`; only new or changed files are re-hashed on refresh.
public final class PhotoLibrary {
    public enum IngestResult: Equatable {
        /// New content, moved into its month folder.
        case imported(path: String, sha: String)
        /// Identical content was already in the library; the downloaded copy was discarded.
        case duplicate(path: String, sha: String)

        public var path: String {
            switch self { case .imported(let p, _), .duplicate(let p, _): return p }
        }
        public var sha: String {
            switch self { case .imported(_, let s), .duplicate(_, let s): return s }
        }
    }

    public enum LibraryError: LocalizedError {
        case verifyFailed(String)
        public var errorDescription: String? {
            switch self { case .verifyFailed(let p): return "Copy at \(p) doesn't match what was downloaded" }
        }
    }

    struct Entry: Codable, Equatable {
        var size: Int64
        var mtime: Double
        var sha: String
    }

    static let indexName = ".photoimport-index.json"
    static let stagingName = ".photoimport-staging"

    public let root: URL
    private var entries: [String: Entry] = [:]  // relative path → entry
    private var byHash: [String: String] = [:]  // sha → relative path
    private let fm = FileManager.default

    public init(root: URL) {
        self.root = root.resolvingSymlinksInPath()
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
            rebuildHashIndex()
        }
    }

    /// Downloads land here first. It's inside the library so the final move is an instant same-volume rename.
    public var stagingDir: URL { root.appendingPathComponent(Self.stagingName, isDirectory: true) }
    public var fileCount: Int { entries.count }
    private var indexURL: URL { root.appendingPathComponent(Self.indexName) }

    public func url(for relativePath: String) -> URL { root.appendingPathComponent(relativePath) }

    /// Re-syncs the index with what's actually on disk.
    public func refresh(progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }) throws {
        try? fm.removeItem(at: stagingDir)
        let files = LibraryFiles.list(root)
        var fresh: [String: Entry] = [:]
        for (i, file) in files.enumerated() {
            let (size, mtime) = try stat(file.url)
            if let old = entries[file.rel], old.size == size, old.mtime == mtime {
                fresh[file.rel] = old
            } else {
                fresh[file.rel] = Entry(size: size, mtime: mtime, sha: try FileHasher.sha256(of: file.url))
            }
            progress(i + 1, files.count)
        }
        entries = fresh
        rebuildHashIndex()
        try save()
    }

    /// Path of a library file with exactly this content, if it still exists.
    public func existingPath(forSHA sha: String) -> String? {
        guard let rel = byHash[sha], fm.fileExists(atPath: url(for: rel).path) else { return nil }
        return rel
    }

    /// Moves a freshly downloaded file into its month folder, unless identical content is already in the library.
    public func ingest(_ file: URL, name: String, date: Date) throws -> IngestResult {
        let sha = try FileHasher.sha256(of: file)
        if let existing = existingPath(forSHA: sha) {
            try? fm.removeItem(at: file)
            return .duplicate(path: existing, sha: sha)
        }
        let dir = root.appendingPathComponent(LibraryLayout.folder(for: date), isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = LibraryLayout.uniqueURL(in: dir, name: name)
        try fm.moveItem(at: file, to: dest)
        guard try FileHasher.sha256(of: dest) == sha else { throw LibraryError.verifyFailed(dest.path) }
        let rel = String(dest.path.dropFirst(root.path.count + 1))
        let (size, mtime) = try stat(dest)
        entries[rel] = Entry(size: size, mtime: mtime, sha: sha)
        byHash[sha] = rel
        return .imported(path: rel, sha: sha)
    }

    /// Snapshot of the index: relative path → (size, sha).
    func indexedEntries() -> [String: (size: Int64, sha: String)] {
        entries.mapValues { ($0.size, $0.sha) }
    }

    public func save() throws {
        try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
    }

    private func rebuildHashIndex() {
        byHash = [:]
        for (rel, entry) in entries.sorted(by: { $0.key < $1.key }) where byHash[entry.sha] == nil {
            byHash[entry.sha] = rel
        }
    }

    private func stat(_ url: URL) throws -> (Int64, Double) {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return ((attrs[.size] as? NSNumber)?.int64Value ?? -1,
                (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
    }
}
