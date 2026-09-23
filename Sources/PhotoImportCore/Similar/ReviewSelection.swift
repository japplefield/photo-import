import Foundation

public struct ReviewGroup: Identifiable, Equatable, Sendable {
    public let id: Int
    public let paths: [String]

    public init(id: Int, paths: [String]) {
        self.id = id
        self.paths = paths
    }
}

/// Which photos the user has marked for deletion. A group only counts once it's been opened (`open`), so
/// nothing is ever deleted from a group the user hasn't looked at.
public struct ReviewSelection: Equatable, Sendable {
    public struct Summary: Equatable, Sendable {
        public var reviewedGroups = 0
        public var toDelete = 0
        public var toKeep = 0
        /// Reviewed groups where every photo is marked for deletion.
        public var groupsWithNothingKept: [Int] = []
    }

    private var marked: [Int: Set<String>] = [:]

    public init() {}

    public func isReviewed(_ group: ReviewGroup) -> Bool { marked[group.id] != nil }

    /// First time a group is opened: keep the recommended photo and mark the rest for deletion.
    public mutating func open(_ group: ReviewGroup, recommended: String?) {
        guard marked[group.id] == nil else { return }
        guard let recommended, group.paths.contains(recommended) else {
            marked[group.id] = []
            return
        }
        marked[group.id] = Set(group.paths).subtracting([recommended])
    }

    public func isMarked(_ path: String, in group: ReviewGroup) -> Bool { marked[group.id]?.contains(path) ?? false }

    public mutating func toggle(_ path: String, in group: ReviewGroup) {
        var set = marked[group.id] ?? []
        if set.contains(path) { set.remove(path) } else { set.insert(path) }
        marked[group.id] = set
    }

    public mutating func keepAll(_ group: ReviewGroup) { marked[group.id] = [] }

    public mutating func keepOnly(_ path: String, in group: ReviewGroup) {
        marked[group.id] = Set(group.paths).subtracting([path])
    }

    public func markedPaths(in group: ReviewGroup) -> [String] {
        group.paths.filter { isMarked($0, in: group) }
    }

    public func summary(of groups: [ReviewGroup]) -> Summary {
        var s = Summary()
        for group in groups where isReviewed(group) {
            let deleting = markedPaths(in: group).count
            s.reviewedGroups += 1
            s.toDelete += deleting
            s.toKeep += group.paths.count - deleting
            if deleting == group.paths.count { s.groupsWithNothingKept.append(group.id) }
        }
        return s
    }

    /// Forget groups that are done (e.g. after their deletions were carried out).
    public mutating func forget(_ groupIDs: [Int]) {
        for id in groupIDs { marked[id] = nil }
    }
}
