import Foundation
import XCTest
@testable import PhotoImportCore

/// A fake phone file. `reads` lets a test return different bytes on later downloads (e.g. a corrupted re-read).
final class FakeFile: ImportSourceFile {
    let name: String
    let size: Int64
    let deviceDate: Date?
    private let reads: [Data]
    private(set) var downloads = 0
    var failDownloads = false

    init(_ name: String, _ data: Data, date: Date? = FakeFile.defaultDate, reportedSize: Int64? = nil, laterReads: [Data] = []) {
        self.name = name
        self.size = reportedSize ?? Int64(data.count)
        self.deviceDate = date
        self.reads = [data] + laterReads
    }

    static let defaultDate = date(2026, 9, 3)

    func download(to dir: URL) async throws -> URL {
        if failDownloads { throw URLError(.cannotOpenFile) }
        let data = reads[min(downloads, reads.count - 1)]
        downloads += 1
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}

final class DeleteRecorder {
    var deleted: [String] = []
    var fail = false
    func deleter() -> Importer.Deleter {
        { item in
            if self.fail { throw URLError(.cancelled) }
            self.deleted.append(item.main.name)
        }
    }
}

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0, _ s: Double = 0) -> Date {
    var c = DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: Int(s))
    c.nanosecond = Int((s - Double(Int(s))) * 1e9)
    return Calendar.current.date(from: c)!
}

func bytes(_ s: String) -> Data { Data(s.utf8) }

class TempDirTestCase: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dir = dir.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func write(_ rel: String, _ data: Data) throws -> URL {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// Relative paths of all visible files under `dir`.
    func files() -> [String] { LibraryFiles.list(dir).map(\.rel) }
}
