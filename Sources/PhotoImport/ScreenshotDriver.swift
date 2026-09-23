import AppKit
import PhotoImportCore

/// Regenerates the README screenshots: `PhotoImport --screenshots <dir> -libraryPath <demo folder>`.
/// Drives the real UI against a demo library and renders the window into PNGs, which needs no
/// screen-recording permission. The Import tab shows a staged "finished" state since no phone is involved.
@MainActor
enum ScreenshotDriver {
    static func runIfRequested(phone: PhoneConnection, importModel: ImportModel, reviewModel: ReviewModel,
                               duplicatesModel: DuplicatesModel, navigation: Navigation) async {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshots"), i + 1 < args.count else { return }
        let out = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if !CGPreflightScreenCaptureAccess() {
            // Adds Photo Import to System Settings → Privacy & Security → Screen & System Audio Recording.
            _ = CGRequestScreenCaptureAccess()
            print("No Screen Recording permission; falling back to rendered screenshots.")
        }

        await pause(1)
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else { fatalError("no window") }
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.center()

        // Import: a finished run.
        phone.showDemoPhone(name: "iPhone", itemCount: 412)
        importModel.stats = {
            var s = ImportStats(total: 412)
            s.processed = 412
            s.imported = 388
            s.alreadyInLibrary = 24
            return s
        }()
        importModel.lastImported = ["demo"]
        importModel.phase = .finished
        importModel.log = ["Done. 388 copied, 24 already in the library."]
        navigation.tab = .importing
        await pause(1)
        capture(window, out, "import.png")

        // Similar Photos: pick the first group, let the recommendation load.
        navigation.tab = .similar
        reviewModel.scan()
        await waitUntil { reviewModel.phase == .ready && !reviewModel.groups.isEmpty }
        if let group = reviewModel.groups.first(where: { $0.photos.contains { $0.id.hasSuffix("IMG_8243.HEIC") } }) {
            reviewModel.selectedID = group.id
            await waitUntil { reviewModel.analyses[group.id] != nil }
        }
        await pause(2)
        capture(window, out, "similar.png")

        // Large preview of the recommended shot.
        if let group = reviewModel.selectedGroup {
            reviewModel.previewPhotoID = reviewModel.analyses[group.id]?.recommended ?? group.photos.first?.id
            await pause(2)
            capture(window, out, "preview.png")
            reviewModel.previewPhotoID = nil
        }

        // The "nothing kept" warning.
        if let group = reviewModel.groups.first(where: { $0.photos.contains { $0.id.hasSuffix("IMG_8092.HEIC") } }) {
            reviewModel.selectedID = group.id
            await waitUntil { reviewModel.analyses[group.id] != nil }
            for photo in group.photos where !reviewModel.isMarked(photo, in: group) { reviewModel.toggle(photo, in: group) }
            await pause(2)
            capture(window, out, "nothing-kept-warning.png")
        }

        // Exact duplicates.
        navigation.tab = .duplicates
        duplicatesModel.scan()
        await waitUntil { duplicatesModel.phase == .ready }
        await pause(2)
        capture(window, out, "duplicates.png")

        NSApp.terminate(nil)
    }

    private static func capture(_ window: NSWindow, _ dir: URL, _ name: String) {
        let url = dir.appendingPathComponent(name)
        // A real window capture (with shadow) needs Screen Recording permission for this app. Without it, render
        // the view hierarchy instead; that works everywhere but can't draw translucent "glass" controls.
        if CGPreflightScreenCaptureAccess() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-l", String(window.windowNumber), url.path]
            try? p.run()
            p.waitUntilExit()
            print("wrote \(name) (window capture)")
            return
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
        print("wrote \(name)")
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func waitUntil(timeout: Double = 120, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await pause(0.2) }
    }
}
