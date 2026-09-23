import AppKit
import PhotoImportCore

@MainActor
final class ReviewModel: ObservableObject {
    struct Photo: Identifiable, Hashable {
        /// Path relative to the library root.
        let id: String
        let url: URL
        let taken: Date
    }

    struct Group: Identifiable {
        let id: Int
        let photos: [Photo]
        var review: ReviewGroup { ReviewGroup(id: id, paths: photos.map(\.id)) }
    }

    struct Analysis {
        var scores: [String: PhotoScore] = [:]
        /// Sharpness relative to the sharpest photo in the group, 0–1.
        var relativeSharpness: [String: Double] = [:]
        var recommended: String?
        var reasons: [String] = []
        /// Photos that are byte-for-byte copies of an earlier photo in the group.
        var identicalCopies: Set<String> = []
    }

    enum Phase: Equatable {
        case idle
        case scanning(done: Int, total: Int)
        case ready
        case trashing
    }

    private static let gapKey = "similarMaxGap"

    @Published var phase: Phase = .idle
    @Published private(set) var groups: [Group] = []
    @Published private(set) var selection = ReviewSelection()
    @Published private(set) var analyses: [Int: Analysis] = [:]
    @Published var confirmingTrash = false
    /// When set, only groups containing at least one of these paths are shown (e.g. the latest import).
    @Published private(set) var onlyIncluding: Set<String>?
    @Published var message: String?
    @Published var selectedID: Int? {
        didSet {
            previewPhotoID = nil
            hoveredPhotoID = nil
            if let selectedID { opened(selectedID) }
        }
    }
    /// Photo under the pointer; Space opens it large.
    @Published var hoveredPhotoID: String?
    /// Photo shown in the large preview, if open.
    @Published var previewPhotoID: String?
    @Published var maxGap: Double {
        didSet { UserDefaults.standard.set(maxGap, forKey: Self.gapKey) }
    }

    let settings: LibrarySettings
    private var analyzing: Set<Int> = []

    init(settings: LibrarySettings) {
        self.settings = settings
        let saved = UserDefaults.standard.double(forKey: Self.gapKey)
        maxGap = saved > 0 ? saved : 2
    }

    var summary: ReviewSelection.Summary { selection.summary(of: groups.map(\.review)) }
    var selectedGroup: Group? { groups.first { $0.id == selectedID } }

    /// Rescans with the current filter kept (e.g. after changing the gap).
    func rescan() { scan(onlyIncluding: onlyIncluding) }

    func scan(onlyIncluding paths: Set<String>? = nil) {
        guard let root = settings.root else { return }
        let gap = maxGap
        onlyIncluding = paths
        phase = .scanning(done: 0, total: 0)
        message = nil
        Task {
            let refs = await Task.detached(priority: .userInitiated) {
                PhotoDateIndex(root: root).scan { done, total in
                    if done % 250 == 0 || done == total {
                        Task { @MainActor in self.phase = .scanning(done: done, total: total) }
                    }
                }
            }.value
            let libraryRoot = root.resolvingSymlinksInPath()
            // Newest first, so recent bursts come up before old ones.
            let bursts = paths.map { SimilarGrouper.groups(refs, maxGap: gap, including: $0) }
                ?? SimilarGrouper.groups(refs, maxGap: gap)
            groups = bursts.reversed().enumerated().map { i, burst in
                Group(id: i, photos: burst.map { Photo(id: $0.path, url: libraryRoot.appendingPathComponent($0.path), taken: $0.taken) })
            }
            selection = ReviewSelection()
            analyses = [:]
            analyzing = []
            phase = .ready
            selectedID = groups.first?.id
        }
    }

    // MARK: Selection

    func isMarked(_ photo: Photo, in group: Group) -> Bool { selection.isMarked(photo.id, in: group.review) }
    func toggle(_ photo: Photo, in group: Group) { selection.toggle(photo.id, in: group.review) }
    func keepAll(_ group: Group) { selection.keepAll(group.review) }

    func keepOnlyRecommended(_ group: Group) {
        guard let best = analyses[group.id]?.recommended else { return }
        selection.keepOnly(best, in: group.review)
    }

    func move(_ offset: Int) {
        guard let i = groups.firstIndex(where: { $0.id == selectedID }) else { return }
        let j = i + offset
        if groups.indices.contains(j) { selectedID = groups[j].id }
    }

    func selectFirstGroupWithNothingKept() {
        if let id = summary.groupsWithNothingKept.first { selectedID = id }
    }

    // MARK: Keyboard

    /// Handles a key press on the review screen; returns false to let the key through (e.g. ↑ ↓ in the list).
    func handleKey(_ event: NSEvent) -> Bool {
        guard phase == .ready, !confirmingTrash, let group = selectedGroup,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let key: ReviewKey
        switch event.keyCode {
        case 123: key = .left
        case 124: key = .right
        case 49: key = .space
        case 53: key = .escape
        default:
            guard event.charactersIgnoringModifiers?.lowercased() == "d" else { return false }
            key = .toggle
        }
        let index = previewPhotoID.flatMap { id in group.photos.firstIndex { $0.id == id } }
        switch ReviewKeys.action(for: key, previewIndex: index, photoCount: group.photos.count) {
        case .none:
            // In the preview, swallow arrows at the ends so they don't fall through and change groups.
            return index != nil
        case .previousGroup: move(-1)
        case .nextGroup: move(1)
        case .openPreview:
            previewPhotoID = hoveredPhotoID ?? analyses[group.id]?.recommended ?? group.photos.first?.id
        case .closePreview: previewPhotoID = nil
        case .showPhoto(let i): previewPhotoID = group.photos[i].id
        case .toggleCurrent:
            if let i = index, analyses[group.id] != nil { toggle(group.photos[i], in: group) }
        }
        return true
    }

    // MARK: Analysis

    private func opened(_ id: Int) {
        analyze(id)
        if let i = groups.firstIndex(where: { $0.id == id }), groups.indices.contains(i + 1) { analyze(groups[i + 1].id) }
        applyDefaults(id)
    }

    /// Defaults (keep the recommended photo, mark the rest) apply only once the group is on screen,
    /// so a prefetched group the user hasn't seen never counts toward deletion.
    private func applyDefaults(_ id: Int) {
        guard id == selectedID, let analysis = analyses[id], let group = groups.first(where: { $0.id == id }) else { return }
        selection.open(group.review, recommended: analysis.recommended)
    }

    private func analyze(_ id: Int) {
        guard analyses[id] == nil, !analyzing.contains(id), let group = groups.first(where: { $0.id == id }) else { return }
        analyzing.insert(id)
        let photos = group.photos
        Task {
            let analysis = await Task.detached(priority: .userInitiated) { Self.analyze(photos) }.value
            analyzing.remove(id)
            guard groups.contains(where: { $0.id == id }) else { return }
            analyses[id] = analysis
            applyDefaults(id)
        }
    }

    nonisolated private static func analyze(_ photos: [Photo]) -> Analysis {
        var analysis = Analysis()
        var bySHA: [String: [String]] = [:]
        for photo in photos {
            if let score = try? PhotoScorer.score(url: photo.url) { analysis.scores[photo.id] = score }
            if let sha = try? FileHasher.sha256(of: photo.url) { bySHA[sha, default: []].append(photo.id) }
        }
        // Of each set of identical files, the one Exact Duplicates would keep is the original; the rest are copies.
        var original: [String: String] = [:]
        for ids in bySHA.values where ids.count > 1 {
            let ordered = Duplicates.preferredOrder(ids)
            for id in ordered.dropFirst() {
                analysis.identicalCopies.insert(id)
                original[id] = ordered[0]
            }
        }
        let ordered = photos.map { analysis.scores[$0.id] ?? PhotoScore(sharpness: 0) }
        let maxSharp = max(ordered.map(\.sharpness).max() ?? 0, 1e-9)
        for (photo, score) in zip(photos, ordered) { analysis.relativeSharpness[photo.id] = score.sharpness / maxSharp }
        if let rec = Recommender.recommend(ordered) {
            let best = photos[rec.best].id
            analysis.recommended = original[best] ?? best
            analysis.reasons = rec.reasons
        }
        return analysis
    }

    // MARK: Trash

    func trashMarked() {
        let reviewed = groups.filter { selection.isReviewed($0.review) }
        let urls = reviewed.flatMap { group in
            selection.markedPaths(in: group.review).compactMap { path in group.photos.first { $0.id == path }?.url }
        }
        guard !urls.isEmpty else { return }
        phase = .trashing
        Task {
            let result = await Task.detached(priority: .userInitiated) { await LibraryCleanup.moveToTrash(urls) }.value
            // Reviewed groups are done; drop them so the list only shows what's left to look at.
            let done = Set(reviewed.map(\.id))
            let nextID = groups.first { !done.contains($0.id) }?.id
            groups.removeAll { done.contains($0.id) }
            selection.forget(Array(done))
            for id in done { analyses[id] = nil }
            phase = .ready
            selectedID = nextID
            var text = "Moved \(result.photos.count) photo\(result.photos.count == 1 ? "" : "s") to the Trash"
            if !result.sidecars.isEmpty {
                text += ", plus \(result.sidecars.count) Live Photo video\(result.sidecars.count == 1 ? "" : "s") and edit files that belong to them"
            }
            text += "."
            if !result.failures.isEmpty {
                text += " \(result.failures.count) couldn't be moved: " + result.failures.prefix(3).map { $0.0.lastPathComponent }.joined(separator: ", ")
            }
            message = text
        }
    }
}
