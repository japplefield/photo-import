import Foundation

/// Where files live inside the library: `<year>/<MM-year>/<name>`, e.g. `2026/09-2026/IMG_0001.HEIC`.
public enum LibraryLayout {
    public static func folder(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d/%02d-%04d", c.year!, c.month!, c.year!)
    }

    /// Finder-style conflict avoidance: `IMG_1.HEIC` → `IMG_1 1.HEIC` → `IMG_1 2.HEIC`.
    public static func uniqueURL(in dir: URL, name: String, fileManager: FileManager = .default) -> URL {
        let first = dir.appendingPathComponent(name)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Keeps a sidecar paired with its photo when the photo had to be renamed:
    /// photo `IMG_1.HEIC` saved as `IMG_1 1.HEIC` → sidecar `IMG_1.MOV` becomes `IMG_1 1.MOV`.
    public static func sidecarName(_ sidecar: String, originalMain: String, savedMain: String) -> String {
        let origStem = (originalMain as NSString).deletingPathExtension
        let savedStem = (savedMain as NSString).deletingPathExtension
        let sideStem = (sidecar as NSString).deletingPathExtension
        let ext = (sidecar as NSString).pathExtension
        guard savedStem.hasPrefix(origStem) else { return sidecar }
        let suffix = String(savedStem.dropFirst(origStem.count))
        let newStem: String
        if sideStem == origStem {
            newStem = sideStem + suffix
        } else if origStem.hasPrefix("IMG_"), sideStem == "IMG_O" + origStem.dropFirst(4) {
            newStem = sideStem + suffix  // original-adjustments file, e.g. IMG_O1234.AAE
        } else {
            return sidecar
        }
        return ext.isEmpty ? newStem : "\(newStem).\(ext)"
    }
}

enum LibraryFiles {
    /// All regular, non-hidden files under `root`, as (relative path, URL), sorted by path.
    static func list(_ root: URL, where include: (URL) -> Bool = { _ in true }) -> [(rel: String, url: URL)] {
        // The path-based enumerator yields paths relative to `root` directly, so they stay correct even when
        // `root` is reached through a symlink (e.g. /var → /private/var).
        guard let e = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var out: [(rel: String, url: URL)] = []
        while let rel = e.nextObject() as? String {
            let type = e.fileAttributes?[.type] as? FileAttributeType
            if (rel as NSString).lastPathComponent.hasPrefix(".") {
                if type == .typeDirectory { e.skipDescendants() }
                continue
            }
            guard type == .typeRegular else { continue }
            let url = root.appendingPathComponent(rel)
            if include(url) { out.append((rel, url)) }
        }
        return out.sorted { $0.rel < $1.rel }
    }
}
