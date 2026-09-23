import Foundation

/// Files in the library with byte-for-byte identical contents.
public struct DuplicateSet: Identifiable, Equatable, Sendable {
    /// The shared SHA-256.
    public let id: String
    public let size: Int64
    /// Relative paths, best copy to keep first.
    public let paths: [String]

    public init(id: String, size: Int64, paths: [String]) {
        self.id = id
        self.size = size
        self.paths = Duplicates.preferredOrder(paths)
    }
}

public enum Duplicates {
    /// Which copy to keep by default: one without a Finder-style " 1" suffix, then the shortest path, then A→Z.
    public static func preferredOrder(_ paths: [String]) -> [String] {
        func hasCopySuffix(_ path: String) -> Bool {
            let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            return stem.range(of: #" \d+$"#, options: .regularExpression) != nil
        }
        return paths.sorted { a, b in
            let (sa, sb) = (hasCopySuffix(a), hasCopySuffix(b))
            if sa != sb { return !sa }
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
    }

    public struct Result: Sendable {
        public var removed: [String] = []
        public var bytes: Int64 = 0
        /// Paths left alone because they (or their keeper) no longer matched the set's contents.
        public var skipped: [String] = []
        public var failures: [(String, String)] = []
    }

    /// Moves every copy except `keep[set.id]` (default: the first path) to the Trash. Right before moving a copy,
    /// both it and the keeper are re-hashed; anything that doesn't match exactly is left alone. Never removes the
    /// keeper, so at least one copy of every file always remains.
    public static func removeExtras(_ sets: [DuplicateSet], keep: [String: String] = [:], root: URL,
                                    trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) -> Result {
        var result = Result()
        for set in sets {
            let keeper = keep[set.id].flatMap { set.paths.contains($0) ? $0 : nil } ?? set.paths[0]
            let keeperURL = root.appendingPathComponent(keeper)
            guard (try? FileHasher.sha256(of: keeperURL)) == set.id else {
                result.skipped += set.paths.filter { $0 != keeper }
                continue
            }
            for path in set.paths where path != keeper {
                let url = root.appendingPathComponent(path)
                guard (try? FileHasher.sha256(of: url)) == set.id else {
                    result.skipped.append(path)
                    continue
                }
                do {
                    try trash(url)
                    result.removed.append(path)
                    result.bytes += set.size
                } catch {
                    result.failures.append((path, error.localizedDescription))
                }
            }
        }
        return result
    }
}

extension PhotoLibrary {
    /// Sets of 2+ indexed files with identical contents, largest waste first. Call `refresh()` first.
    public func duplicateSets() -> [DuplicateSet] {
        var byHash: [String: (size: Int64, paths: [String])] = [:]
        for (path, entry) in indexedEntries() {
            byHash[entry.sha, default: (entry.size, [])].paths.append(path)
        }
        return byHash.filter { $0.value.paths.count > 1 }
            .map { DuplicateSet(id: $0.key, size: $0.value.size, paths: $0.value.paths) }
            .sorted { (Int64($0.paths.count - 1) * $0.size, $1.id) > (Int64($1.paths.count - 1) * $1.size, $0.id) }
    }
}
