import Foundation
import PhotoImportCore

/// Command-line modes. Read-only with respect to the phone: nothing here ever deletes.
enum Headless {
    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }

    /// `PhotoImport --import-to <folder>`: copy everything from the connected iPhone, sorted and deduplicated.
    static func importTo(_ path: String) -> Never {
        let phone = PhoneConnection()
        phone.start()
        let deadline = Date().addingTimeInterval(180)
        while !phone.isReady, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        guard phone.isReady else {
            print("No iPhone ready (\(phone.state)). Connect it, unlock it, and tap Trust.")
            exit(1)
        }
        let items = phone.currentItems()
        print("\(items.count) items on the iPhone")

        let library = PhotoLibrary(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        let result = Box<ImportStats?>(nil)
        Task.detached {
            do {
                try library.refresh()
            } catch {
                print("Couldn't read \(path): \(error.localizedDescription)")
                exit(1)
            }
            print("Library has \(library.fileCount) files")
            let importer = Importer(library: library)
            importer.onLog = { print($0) }
            importer.onStats = { s in if s.processed % 100 == 0, s.processed > 0 { print("progress \(s)") } }
            result.value = await importer.run(items)
        }
        while result.value == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
        print("finished \(result.value!)")
        exit(result.value!.failed == 0 ? 0 : 2)
    }

    /// `PhotoImport --similar <folder> [--limit N]`: list similar-photo groups and the recommended pick for the newest N.
    static func similar(_ path: String, limit: Int) -> Never {
        let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).resolvingSymlinksInPath()
        let refs = PhotoDateIndex(root: root).scan()
        let groups = SimilarGrouper.groups(refs, maxGap: 2)
        let sizes = Dictionary(grouping: groups, by: \.count).mapValues(\.count).sorted { $0.key < $1.key }
        print("\(refs.count) photos, \(groups.count) groups covering \(groups.reduce(0) { $0 + $1.count }) photos")
        print("group sizes: " + sizes.map { "\($0.key):\($0.value)" }.joined(separator: " "))
        for group in groups.suffix(limit).reversed() {
            let scores = group.map { (try? PhotoScorer.score(url: root.appendingPathComponent($0.path))) ?? PhotoScore(sharpness: 0) }
            guard let rec = Recommender.recommend(scores) else { continue }
            let span = group.last!.taken.timeIntervalSince(group.first!.taken)
            print("\n\(group.first!.taken) · \(group.count) photos over \(String(format: "%.2f", span))s · reasons: \(rec.reasons)")
            for (i, (ref, s)) in zip(group, scores).enumerated() {
                let tilt = s.tiltDegrees.map { String(format: "%.1f°", $0) } ?? "-"
                let look = s.aesthetics.map { String(format: "%.2f", $0) } ?? "-"
                print(String(format: "  %@ %-40@ total=%.2f sharp=%8.1f faces=%d open=%d tilt=%@ look=%@",
                             i == rec.best ? "★" : " ", ref.path as NSString, rec.totals[i], s.sharpness,
                             s.faces, s.facesWithEyesOpen, tilt as NSString, look as NSString))
            }
        }
        exit(0)
    }
}
