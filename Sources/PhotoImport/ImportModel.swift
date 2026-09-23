import Foundation
import PhotoImportCore

@MainActor
final class ImportModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case indexing(done: Int, total: Int)
        case importing
        case finished
    }

    private static let deleteKey = "deleteAfterImport"

    @Published var phase: Phase = .idle
    @Published var stats = ImportStats()
    @Published var log: [String] = []
    @Published var confirmingDelete = false
    /// Library paths copied by the most recent run, for "review similar photos from this import".
    @Published var lastImported: Set<String> = []
    @Published var deleteAfterImport: Bool {
        didSet { UserDefaults.standard.set(deleteAfterImport, forKey: Self.deleteKey) }
    }

    let phone: PhoneConnection
    let settings: LibrarySettings
    private let cancel = CancelFlag()

    init(phone: PhoneConnection, settings: LibrarySettings) {
        self.phone = phone
        self.settings = settings
        deleteAfterImport = UserDefaults.standard.bool(forKey: Self.deleteKey)
    }

    var isRunning: Bool { phase != .idle && phase != .finished }
    var canStart: Bool { !isRunning && phone.isReady && settings.root != nil && phone.itemCount > 0 }

    /// With deletion on, the user confirms every run. The setting alone never deletes anything.
    func startTapped() {
        if deleteAfterImport { confirmingDelete = true } else { start(deleting: false) }
    }

    func start(deleting: Bool) {
        guard let root = settings.root, !isRunning else { return }
        let items = phone.currentItems()
        let phone = self.phone
        cancel.set(false)
        log = []
        lastImported = []
        stats = ImportStats(total: items.count)
        phase = .indexing(done: 0, total: 0)

        Task {
            let library = PhotoLibrary(root: root)
            do {
                // Index what's already in the folder so nothing gets copied twice. Cached after the first run.
                try await Task.detached(priority: .userInitiated) {
                    try library.refresh { done, total in
                        if done % 200 == 0 || done == total {
                            Task { @MainActor in self.phase = .indexing(done: done, total: total) }
                        }
                    }
                }.value
            } catch {
                append("Couldn't read the library folder: \(error.localizedDescription)")
                phase = .idle
                return
            }

            phase = .importing
            let importer = Importer(library: library, deleter: deleting ? { item in try await phone.delete(item) } : nil)
            let cancel = self.cancel
            importer.isCancelled = { cancel.isSet }
            importer.onStats = { s in Task { @MainActor in self.stats = s } }
            importer.onLog = { line in Task { @MainActor in self.append(line) } }
            let (final, copied) = await Task.detached(priority: .userInitiated) {
                (await importer.run(items), importer.importedPaths)
            }.value
            stats = final
            lastImported = copied
            phase = .finished
            append("Done. \(final.imported) copied, \(final.alreadyInLibrary) already in the library"
                + (deleting ? ", \(final.deleted) deleted from iPhone" : "")
                + (final.failed > 0 ? ", \(final.failed) failed" : "") + ".")
        }
    }

    func stop() { cancel.set(true) }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 500 { log.removeFirst(log.count - 500) }
    }
}
