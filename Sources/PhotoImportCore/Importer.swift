import Foundation

/// One file on the phone. The app backs this with ImageCaptureCore; tests use fakes.
public protocol ImportSourceFile: AnyObject {
    var name: String { get }
    /// Size the phone reports; every download must match it.
    var size: Int64 { get }
    var deviceDate: Date? { get }
    /// Downloads the file into `dir` and returns its local URL.
    func download(to dir: URL) async throws -> URL
}

/// A photo or video plus its sidecars (Live Photo video, edit files). They're copied and deleted together.
public struct ImportItem {
    public let main: ImportSourceFile
    public let sidecars: [ImportSourceFile]

    public init(main: ImportSourceFile, sidecars: [ImportSourceFile] = []) {
        self.main = main
        self.sidecars = sidecars
    }

    public var parts: [ImportSourceFile] { [main] + sidecars }
}

/// Counts are per item (a photo together with its sidecars).
public struct ImportStats: Equatable, Sendable, CustomStringConvertible {
    public var total = 0
    public var processed = 0
    public var imported = 0
    public var alreadyInLibrary = 0
    public var failed = 0
    public var deleted = 0
    public var deleteFailed = 0

    public init(total: Int = 0) { self.total = total }

    public var description: String {
        "processed=\(processed)/\(total) imported=\(imported) alreadyInLibrary=\(alreadyInLibrary) "
            + "failed=\(failed) deleted=\(deleted) deleteFailed=\(deleteFailed)"
    }
}

public enum ImportError: LocalizedError {
    case sizeMismatch(name: String, expected: Int64, actual: Int64)
    case secondReadMismatch(name: String)
    case missingFromLibrary(name: String)

    public var errorDescription: String? {
        switch self {
        case let .sizeMismatch(name, expected, actual):
            return "\(name): downloaded \(actual) bytes but the iPhone reports \(expected)"
        case .secondReadMismatch(let name):
            return "\(name): a second read from the iPhone didn't match the copy, so it was not deleted"
        case .missingFromLibrary(let name):
            return "\(name): copy is no longer in the library, so it was not deleted"
        }
    }
}

/// Copies items into the library one at a time and, only if a deleter is supplied, deletes each item from the
/// phone after every part of it has (1) landed in the library and (2) matched a second, independent read.
public final class Importer {
    public typealias Deleter = (ImportItem) async throws -> Void

    public var onStats: (ImportStats) -> Void = { _ in }
    public var onLog: (String) -> Void = { _ in }
    public var isCancelled: () -> Bool = { false }
    /// Library paths of files this run actually copied (not ones that were already there).
    public private(set) var importedPaths: Set<String> = []

    private let library: PhotoLibrary
    private let deleter: Deleter?
    private var stats = ImportStats()

    /// Pass a `deleter` only when the user turned on "delete after import". Without one nothing is ever deleted.
    public init(library: PhotoLibrary, deleter: Deleter? = nil) {
        self.library = library
        self.deleter = deleter
    }

    public func run(_ items: [ImportItem]) async -> ImportStats {
        stats = ImportStats(total: items.count)
        importedPaths = []
        onStats(stats)
        for item in items {
            if isCancelled() {
                onLog("Stopped.")
                break
            }
            do {
                let shas = try await copy(item)
                if let deleter {
                    try await verifyWithSecondRead(item, expected: shas)
                    do {
                        try await deleter(item)
                        stats.deleted += 1
                    } catch {
                        stats.deleteFailed += 1
                        onLog("Couldn't delete \(item.main.name) from the iPhone: \(error.localizedDescription)")
                    }
                }
            } catch {
                stats.failed += 1
                onLog("\(item.main.name): \(error.localizedDescription)")
            }
            stats.processed += 1
            if stats.processed % 25 == 0 { try? library.save() }
            onStats(stats)
        }
        try? library.save()
        onStats(stats)
        return stats
    }

    /// Returns the content hash of each part, in `item.parts` order.
    private func copy(_ item: ImportItem) async throws -> [String] {
        var shas: [String] = []
        var date = Date()
        var savedMain = item.main.name
        var anyNew = false
        for (i, part) in item.parts.enumerated() {
            let local = try await fetch(part)
            defer { cleanup(local) }
            if i == 0 { date = await CaptureDate.read(from: local) ?? part.deviceDate ?? Date() }
            // Sidecars go in the main file's month folder, named to stay paired with it.
            let name = i == 0 ? part.name
                : LibraryLayout.sidecarName(part.name, originalMain: item.main.name, savedMain: savedMain)
            let result = try library.ingest(local, name: name, date: date)
            if i == 0 { savedMain = (result.path as NSString).lastPathComponent }
            if case .imported = result {
                anyNew = true
                importedPaths.insert(result.path)
            }
            shas.append(result.sha)
        }
        if anyNew { stats.imported += 1 } else { stats.alreadyInLibrary += 1 }
        return shas
    }

    private func verifyWithSecondRead(_ item: ImportItem, expected: [String]) async throws {
        for (part, sha) in zip(item.parts, expected) {
            guard library.existingPath(forSHA: sha) != nil else { throw ImportError.missingFromLibrary(name: part.name) }
            let local = try await fetch(part)
            defer { cleanup(local) }
            guard try FileHasher.sha256(of: local) == sha else { throw ImportError.secondReadMismatch(name: part.name) }
        }
    }

    /// Downloads into a fresh staging folder and checks the size against what the phone reports.
    private func fetch(_ part: ImportSourceFile) async throws -> URL {
        let dir = library.stagingDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let url = try await part.download(to: dir)
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let actual = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            guard actual == part.size else {
                throw ImportError.sizeMismatch(name: part.name, expected: part.size, actual: actual)
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    private func cleanup(_ local: URL) {
        try? FileManager.default.removeItem(at: local.deletingLastPathComponent())
    }
}
