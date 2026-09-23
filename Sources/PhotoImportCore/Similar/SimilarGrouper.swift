import Foundation

public struct PhotoRef: Hashable, Sendable {
    /// Path relative to the library root.
    public let path: String
    public let taken: Date

    public init(path: String, taken: Date) {
        self.path = path
        self.taken = taken
    }
}

public enum SimilarGrouper {
    /// Bursts of photos: each photo was taken within `maxGap` seconds of the previous one, and the burst is
    /// separated from the photos before and after it by a longer gap. Only bursts of 2+ photos are returned,
    /// oldest first, each sorted by time.
    public static func groups(_ photos: [PhotoRef], maxGap: TimeInterval = 2) -> [[PhotoRef]] {
        let sorted = photos.sorted { ($0.taken, $0.path) < ($1.taken, $1.path) }
        var groups: [[PhotoRef]] = []
        var current: [PhotoRef] = []
        for photo in sorted {
            if let last = current.last, photo.taken.timeIntervalSince(last.taken) > maxGap {
                if current.count > 1 { groups.append(current) }
                current = []
            }
            current.append(photo)
        }
        if current.count > 1 { groups.append(current) }
        return groups
    }

    /// Only the groups containing at least one of `paths`, e.g. photos from the latest import. A group is kept
    /// whole, so a new shot is compared with older ones from the same burst.
    public static func groups(_ photos: [PhotoRef], maxGap: TimeInterval = 2, including paths: Set<String>) -> [[PhotoRef]] {
        groups(photos, maxGap: maxGap).filter { group in group.contains { paths.contains($0.path) } }
    }
}
