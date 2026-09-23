import AppKit
import Foundation

/// The library folder, shared by the Import and Similar Photos tabs.
@MainActor
final class LibrarySettings: ObservableObject {
    private static let rootKey = "libraryPath"

    @Published var root: URL? {
        didSet { UserDefaults.standard.set(root?.path, forKey: Self.rootKey) }
    }

    init() {
        root = UserDefaults.standard.string(forKey: Self.rootKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        panel.message = "Choose the folder your photos are copied into."
        panel.directoryURL = root
        if panel.runModal() == .OK, let url = panel.url { root = url }
    }
}

extension URL {
    /// `~/Pictures/…` rather than the full path with the user name.
    var displayPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

enum AppTab: Hashable {
    case importing
    case similar
    case duplicates
}

@MainActor
final class Navigation: ObservableObject {
    @Published var tab: AppTab = .importing
}

/// Thread-safe stop flag the importer checks between items.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}
