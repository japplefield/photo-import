import Foundation
import ImageCaptureCore
import PhotoImportCore

/// A file on the iPhone, downloadable through ImageCaptureCore.
final class PhoneFile: ImportSourceFile {
    let file: ICCameraFile

    init(_ file: ICCameraFile) { self.file = file }

    var name: String { file.name ?? "unnamed" }
    var size: Int64 { Int64(file.fileSize) }
    var deviceDate: Date? { file.creationDate }

    func download(to dir: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async {
                self.file.requestDownload(options: [.downloadsDirectoryURL: dir, .overwrite: true]) { saved, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: dir.appendingPathComponent(saved ?? self.name))
                    }
                }
            }
        }
    }
}

enum PhoneError: LocalizedError {
    case disconnected
    case notDeleted(String)

    var errorDescription: String? {
        switch self {
        case .disconnected: return "iPhone disconnected"
        case .notDeleted(let name): return "the iPhone didn't confirm deleting \(name)"
        }
    }
}

/// Finds the first connected iPhone (or camera) and keeps an open session to it.
/// ImageCaptureCore calls every delegate method on the main thread.
final class PhoneConnection: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    enum State: Equatable {
        case searching
        case waitingForUnlock(String)
        case loading(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state: State = .searching
    @Published private(set) var itemCount = 0

    private let browser = ICDeviceBrowser()
    private var camera: ICCameraDevice?
    private var openAttempts = 0

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(
            rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    /// Everything on the phone right now, each photo/video with its sidecars.
    func currentItems() -> [ImportItem] {
        (camera?.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }.map { file in
            let sidecars = (file.sidecarFiles ?? []).compactMap { $0 as? ICCameraFile }.map(PhoneFile.init)
            return ImportItem(main: PhoneFile(file), sidecars: sidecars)
        }
    }

    /// Deletes an item (and its sidecars) from the phone. Throws unless the phone confirms the main file is gone.
    func delete(_ item: ImportItem) async throws {
        guard let camera else { throw PhoneError.disconnected }
        guard let main = (item.main as? PhoneFile)?.file else { throw PhoneError.notDeleted(item.main.name) }
        let files: [ICCameraItem] = item.parts.compactMap { ($0 as? PhoneFile)?.file }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async {
                _ = camera.requestDeleteFiles(files, deleteFailed: { _ in }, completion: { result, error in
                    let succeeded = result[.successful] ?? []
                    let confirmed = succeeded.contains { $0 === main || ($0.name == main.name && $0.parentFolder === main.parentFolder) }
                    if confirmed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? PhoneError.notDeleted(item.main.name))
                    }
                })
            }
        }
    }

    // MARK: ICDeviceBrowserDelegate

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard camera == nil, let cam = device as? ICCameraDevice else { return }
        camera = cam
        openAttempts = 0
        cam.delegate = self
        state = .loading(cam.name ?? "iPhone")
        cam.requestOpenSession()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        disconnect(device)
    }

    // MARK: ICDeviceDelegate

    func didRemove(_ device: ICDevice) { disconnect(device) }

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        guard let error, device === camera else { return }
        // iPhones report "locked" for a moment right after connecting, so keep retrying for a while.
        openAttempts += 1
        guard openAttempts < 90 else {
            state = .failed(error.localizedDescription)
            return
        }
        state = .waitingForUnlock(device.name ?? "iPhone")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.camera === device else { return }
            device.requestOpenSession()
        }
    }

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}

    // MARK: ICCameraDeviceDelegate

    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        itemCount = device.mediaFiles?.count ?? 0
        state = .ready(device.name ?? "iPhone")
    }

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) { refreshCount() }
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) { refreshCount() }
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}

    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        if device === camera, !isReady { state = .waitingForUnlock(device.name ?? "iPhone") }
    }

    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        if device === camera, !isReady { state = .loading(device.name ?? "iPhone") }
    }

    /// Screenshot mode only: pretend a phone is connected.
    func showDemoPhone(name: String, itemCount: Int) {
        state = .ready(name)
        self.itemCount = itemCount
    }

    private func refreshCount() {
        if isReady { itemCount = camera?.mediaFiles?.count ?? 0 }
    }

    private func disconnect(_ device: ICDevice) {
        guard device === camera else { return }
        camera = nil
        itemCount = 0
        state = .searching
    }
}
