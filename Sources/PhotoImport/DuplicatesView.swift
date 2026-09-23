import AppKit
import PhotoImportCore
import SwiftUI

struct DuplicatesView: View {
    @ObservedObject var model: DuplicatesModel
    @ObservedObject var settings: LibrarySettings

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle:
                start
            case .scanning(let done, let total):
                VStack(spacing: 12) {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).frame(maxWidth: 360)
                    Text("Checking file contents… \(done.formatted()) of \(total.formatted())").foregroundStyle(.secondary)
                    Text("The first check reads every file and can take several minutes. Later ones are quick.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready, .removing:
                if model.sets.isEmpty {
                    ContentUnavailableView {
                        Label("No duplicates", systemImage: "checkmark.circle")
                    } description: {
                        Text(model.message ?? "Every file in this folder is unique.")
                    } actions: {
                        Button("Check Again") { model.scan() }
                    }
                } else {
                    list
                    bottomBar
                }
            }
        }
        .alert(confirmTitle, isPresented: $model.confirming) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) { model.removeExtras() }
        } message: {
            Text("The copy marked Keep in each set stays where it is. Each file is re-checked to be byte-for-byte identical right before it's moved, and you can put anything back from the Trash until you empty it.")
        }
    }

    private var confirmTitle: String {
        "Move \(model.extraCopies.formatted()) duplicate\(model.extraCopies == 1 ? "" : "s") (\(bytes(model.extraBytes))) to the Trash?"
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }

    private var start: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.on.doc").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Find exact duplicates").font(.title2.bold())
            Text("Finds files whose contents are identical, byte for byte, even if their names or folders differ. Nothing is removed until you review the list and confirm, and one copy of every file is always kept.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            HStack {
                Text(settings.root?.displayPath ?? "No folder chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") { settings.chooseFolder() }
            }
            .frame(maxWidth: 460)
            Button("Find Duplicates") { model.scan() }
                .keyboardShortcut(.defaultAction)
                .disabled(settings.root == nil)
            if let message = model.message { Text(message).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(model.sets.count.formatted()) files have identical copies").font(.headline)
                Spacer()
                Button { model.scan() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Check again")
            }
            .padding(12)
            Divider()
            List(model.sets) { set in
                DuplicateRow(set: set, root: settings.root?.resolvingSymlinksInPath(), model: model)
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("**\(model.extraCopies.formatted())** extra copies will be moved to the Trash · **\(model.included.count.formatted())** kept (one of each)")
                    Text("Frees \(bytes(model.extraBytes)) once the Trash is emptied. Click a copy to keep that one instead, or untick a set to leave it alone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Move \(model.extraCopies.formatted()) to Trash…") { model.confirming = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(model.extraCopies == 0 || model.phase == .removing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

struct DuplicateRow: View {
    let set: DuplicateSet
    let root: URL?
    @ObservedObject var model: DuplicatesModel

    var body: some View {
        let included = model.isIncluded(set)
        let keeper = model.keeper(of: set)
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(get: { included }, set: { model.setIncluded($0, set) }))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .help("Include this set")
            if let root {
                ThumbnailView(url: root.appendingPathComponent(keeper), maxPixel: 160, fill: true)
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(set.paths.count) identical copies · \(ByteCountFormatter.string(fromByteCount: set.size, countStyle: .file)) each")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(set.paths, id: \.self) { path in
                    let isKeeper = path == keeper
                    Button {
                        model.setKeeper(path, in: set)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: isKeeper ? "largecircle.fill.circle" : "circle")
                            Text(path).lineLimit(1).truncationMode(.middle)
                            Text(isKeeper ? "Keep" : (included ? "Remove" : "Leave"))
                                .font(.caption.bold())
                                .foregroundStyle(isKeeper ? .green : (included ? .red : .secondary))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!included)
                    .contextMenu {
                        if let root {
                            Button("Open") { NSWorkspace.shared.open(root.appendingPathComponent(path)) }
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path)]) }
                        }
                    }
                }
            }
            .opacity(included ? 1 : 0.5)
        }
        .padding(.vertical, 4)
    }
}
