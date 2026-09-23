import Foundation
import PhotoImportCore

@MainActor
final class DuplicatesModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case ready
        case removing
    }

    @Published var phase: Phase = .idle
    @Published private(set) var sets: [DuplicateSet] = []
    /// Set id → the copy the user chose to keep (default: the set's first path).
    @Published private(set) var keep: [String: String] = [:]
    /// Sets the user unticked; they're left alone.
    @Published private(set) var excluded: Set<String> = []
    @Published var confirming = false
    @Published var message: String?

    let settings: LibrarySettings

    init(settings: LibrarySettings) { self.settings = settings }

    var included: [DuplicateSet] { sets.filter { !excluded.contains($0.id) } }
    var extraCopies: Int { included.reduce(0) { $0 + $1.paths.count - 1 } }
    var extraBytes: Int64 { included.reduce(0) { $0 + Int64($1.paths.count - 1) * $1.size } }

    func keeper(of set: DuplicateSet) -> String { keep[set.id] ?? set.paths[0] }
    func setKeeper(_ path: String, in set: DuplicateSet) { keep[set.id] = path }
    func isIncluded(_ set: DuplicateSet) -> Bool { !excluded.contains(set.id) }

    func setIncluded(_ included: Bool, _ set: DuplicateSet) {
        if included { excluded.remove(set.id) } else { excluded.insert(set.id) }
    }

    func scan(keepingMessage: Bool = false) {
        guard let root = settings.root else { return }
        if !keepingMessage { message = nil }
        phase = .scanning(done: 0, total: 0)
        Task {
            let found: [DuplicateSet]? = await Task.detached(priority: .userInitiated) {
                let library = PhotoLibrary(root: root)
                do {
                    try library.refresh { done, total in
                        if done % 200 == 0 || done == total {
                            Task { @MainActor in self.phase = .scanning(done: done, total: total) }
                        }
                    }
                } catch {
                    return nil
                }
                return library.duplicateSets()
            }.value
            guard let found else {
                message = "Couldn't read the folder."
                phase = .idle
                return
            }
            sets = found
            keep = [:]
            excluded = []
            phase = .ready
        }
    }

    func removeExtras() {
        guard let root = settings.root?.resolvingSymlinksInPath(), extraCopies > 0 else { return }
        let chosen = included
        let keep = self.keep
        phase = .removing
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Duplicates.removeExtras(chosen, keep: keep, root: root)
            }.value
            var text = "Moved \(result.removed.count) duplicate\(result.removed.count == 1 ? "" : "s") "
                + "(\(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file))) to the Trash."
            if !result.skipped.isEmpty {
                text += " Left \(result.skipped.count) alone because they changed since the scan."
            }
            if !result.failures.isEmpty { text += " \(result.failures.count) couldn't be moved." }
            message = text
            scan(keepingMessage: true)
        }
    }
}
