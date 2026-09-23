import PhotoImportCore
import SwiftUI

struct ImportView: View {
    @ObservedObject var model: ImportModel
    @ObservedObject var phone: PhoneConnection
    @ObservedObject var settings: LibrarySettings
    var reviewSimilar: (Set<String>) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            phoneStatus

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "folder")
                        Text(settings.root?.displayPath ?? "No folder chosen")
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(settings.root == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose…") { settings.chooseFolder() }.disabled(model.isRunning)
                    }
                    Text("Sorted into Year / Month-Year folders by the date each photo was taken. Anything already in this folder is skipped, even under a different name.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(4)
            } label: { Text("Copy to").font(.headline) }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Delete from iPhone after each photo is copied and verified", isOn: $model.deleteAfterImport)
                        .disabled(model.isRunning)
                    if model.deleteAfterImport {
                        Label("A photo is only deleted once its copy is in the folder and a second read from the iPhone matches it exactly. Deleting over the cable may skip Recently Deleted, so treat it as permanent. If iCloud Photos is on, deletions also remove photos from iCloud and your other devices.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(4)
            } label: { Text("After copying").font(.headline) }

            HStack(spacing: 12) {
                if model.isRunning {
                    Button("Stop", role: .cancel) { model.stop() }
                } else {
                    Button(model.deleteAfterImport ? "Import and Delete" : "Import") { model.startTapped() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canStart)
                }
                progress
                if model.phase == .finished, !model.lastImported.isEmpty {
                    Spacer()
                    Button {
                        reviewSimilar(model.lastImported)
                    } label: {
                        Label("Review Similar Photos from This Import", systemImage: "square.stack.3d.up")
                    }
                }
            }

            stats

            List(Array(model.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            .frame(minHeight: 120)
        }
        .padding(20)
        .alert("Delete from iPhone?", isPresented: $model.confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Import and Delete", role: .destructive) { model.start(deleting: true) }
        } message: {
            Text("Up to \(phone.itemCount.formatted()) items will be deleted from \(phoneName), each only after its copy is verified. Deletions may skip Recently Deleted, and if iCloud Photos is on they sync to your other devices.")
        }
    }

    private var phoneName: String {
        switch phone.state {
        case .ready(let n), .loading(let n), .waitingForUnlock(let n): return n
        default: return "your iPhone"
        }
    }

    @ViewBuilder private var phoneStatus: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone").font(.title2)
            switch phone.state {
            case .searching:
                Text("Connect your iPhone with a cable and unlock it.")
            case .waitingForUnlock(let name):
                ProgressView().controlSize(.small)
                Text("Unlock \(name) and tap Trust if asked…")
            case .loading(let name):
                ProgressView().controlSize(.small)
                Text("Reading \(name)…")
            case .ready(let name):
                Text("\(name)").bold()
                Text("\(phone.itemCount.formatted()) photos and videos").foregroundStyle(.secondary)
            case .failed(let message):
                Text("Couldn't open the iPhone: \(message)").foregroundStyle(.red)
            }
            Spacer()
        }
    }

    @ViewBuilder private var progress: some View {
        switch model.phase {
        case .indexing(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Checking what's already in the folder… \(done.formatted()) of \(total.formatted())").font(.caption)
            }
        case .importing:
            ProgressView(value: Double(model.stats.processed), total: Double(max(model.stats.total, 1))) {
                Text("\(model.stats.processed.formatted()) of \(model.stats.total.formatted())").font(.caption)
            }
        default:
            EmptyView()
        }
    }

    private var stats: some View {
        let s = model.stats
        return HStack(spacing: 18) {
            stat("Copied", s.imported, .green)
            stat("Already in folder", s.alreadyInLibrary, .secondary)
            if model.deleteAfterImport || s.deleted > 0 { stat("Deleted from iPhone", s.deleted, .orange) }
            stat("Failed", s.failed + s.deleteFailed, s.failed + s.deleteFailed > 0 ? .red : .secondary)
        }
        .opacity(model.phase == .idle ? 0.4 : 1)
    }

    private func stat(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading) {
            Text(value.formatted()).font(.title3.monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
