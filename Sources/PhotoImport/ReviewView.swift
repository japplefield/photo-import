import AppKit
import PhotoImportCore
import SwiftUI

struct ReviewView: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var settings: LibrarySettings
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .idle:
                start
            case .scanning(let done, let total):
                VStack(spacing: 12) {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .frame(maxWidth: 360)
                    Text("Reading when each photo was taken… \(done.formatted()) of \(total.formatted())")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ready, .trashing:
                if model.groups.isEmpty {
                    ContentUnavailableView {
                        Label("No similar photos", systemImage: "checkmark.circle")
                    } description: {
                        Text(model.message ?? (model.onlyIncluding == nil
                            ? "No photos were taken within \(gapText) of each other."
                            : "None of the photos from your latest import were taken within \(gapText) of another photo."))
                    } actions: {
                        Button("Scan Again") { model.rescan() }
                        if model.onlyIncluding != nil { Button("Show All Groups") { model.scan() } }
                    }
                } else {
                    HSplitView {
                        sidebar.frame(minWidth: 250, idealWidth: 280, maxWidth: 360)
                        detail.frame(minWidth: 520, maxWidth: .infinity)
                    }
                    bottomBar
                }
            }
        }
        .overlay { preview }
        // Arrow-key shortcuts with no modifiers are unreliable in SwiftUI on macOS (arrow events carry
        // function-key flags), so the review screen reads keys directly.
        .onAppear {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard NSApp.modalWindow == nil, event.window?.isKeyWindow == true, event.window?.attachedSheet == nil,
                      !(event.window?.firstResponder is NSText) else { return event }
                return model.handleKey(event) ? nil : event
            }
        }
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
        .alert(trashTitle, isPresented: $model.confirmingTrash) {
            Button("Cancel", role: .cancel) {}
            if !model.summary.groupsWithNothingKept.isEmpty {
                Button("Show Me") { model.selectFirstGroupWithNothingKept() }
            }
            Button(model.summary.groupsWithNothingKept.isEmpty ? "Move to Trash" : "Delete Anyway", role: .destructive) {
                model.trashMarked()
            }
        } message: {
            Text(trashMessage)
        }
    }

    private var gapText: String { "\(model.maxGap.formatted()) second\(model.maxGap == 1 ? "" : "s")" }

    // MARK: Start

    private var start: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.stack.3d.up").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("Find bursts of similar photos").font(.title2.bold())
            Text("Photos taken within a couple of seconds of each other, with a clear gap before and after, are grouped together. Each group gets a recommended best shot, and you choose what to keep.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            gapStepper
            HStack {
                Text(settings.root?.displayPath ?? "No folder chosen").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Button("Choose…") { settings.chooseFolder() }
            }
            .frame(maxWidth: 460)
            Button("Scan Folder") { model.scan() }
                .keyboardShortcut(.defaultAction)
                .disabled(settings.root == nil)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var gapStepper: some View {
        Stepper(value: $model.maxGap, in: 0.5...10, step: 0.5) {
            Text("Similar if taken within \(gapText) of each other")
        }
        .fixedSize()
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(model.groups.count.formatted()) groups of similar photos").font(.headline)
                HStack {
                    gapStepper.font(.caption)
                    Spacer()
                    Button { model.rescan() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Scan again")
                        .buttonStyle(.borderless)
                }
            }
            .padding(10)
            if model.onlyIncluding != nil {
                HStack {
                    Label("From your latest import", systemImage: "line.3.horizontal.decrease.circle.fill")
                        .font(.caption).foregroundStyle(.tint)
                    Spacer()
                    Button("Show All") { model.scan() }.controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            Divider()
            List(selection: $model.selectedID) {
                ForEach(model.groups) { group in
                    GroupRow(group: group, status: status(of: group)).tag(group.id)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func status(of group: ReviewModel.Group) -> GroupRow.Status {
        guard model.selection.isReviewed(group.review) else { return .notReviewed }
        let deleting = model.selection.markedPaths(in: group.review).count
        return deleting == group.photos.count ? .nothingKept : .reviewed(deleting: deleting, keeping: group.photos.count - deleting)
    }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        if let group = model.selectedGroup {
            let analysis = model.analyses[group.id]
            let status = status(of: group)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: group)).font(.title3.bold())
                        if let analysis, !analysis.reasons.isEmpty {
                            Text("Recommended because: " + analysis.reasons.joined(separator: ", ").lowercased().capitalizedFirst)
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Keep Only Recommended") { model.keepOnlyRecommended(group) }.disabled(analysis?.recommended == nil)
                    Button("Keep All") { model.keepAll(group) }
                }

                if case .nothingKept = status {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text("Every photo in this group is marked for deletion, so nothing from this moment would be left.")
                        Spacer()
                        Button("Keep Recommended") { model.keepOnlyRecommended(group) }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    .foregroundStyle(.orange)
                }

                if analysis == nil {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finding the best shot…").foregroundStyle(.secondary)
                    }
                }

                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                        ForEach(group.photos) { photo in
                            PhotoCell(
                                photo: photo,
                                isMarked: model.isMarked(photo, in: group),
                                isRecommended: analysis?.recommended == photo.id,
                                isIdenticalCopy: analysis?.identicalCopies.contains(photo.id) ?? false,
                                isNew: model.onlyIncluding?.contains(photo.id) ?? false,
                                score: analysis?.scores[photo.id],
                                relativeSharpness: analysis?.relativeSharpness[photo.id],
                                canToggle: analysis != nil,
                                toggle: { model.toggle(photo, in: group) },
                                hover: { inside in
                                    if inside { model.hoveredPhotoID = photo.id } else if model.hoveredPhotoID == photo.id { model.hoveredPhotoID = nil }
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }

                HStack {
                    switch status {
                    case .notReviewed:
                        Text("\(group.photos.count) photos").foregroundStyle(.secondary)
                    case .reviewed(let deleting, let keeping):
                        Text("In this group: **\(deleting)** will be deleted, **\(keeping)** kept")
                    case .nothingKept:
                        Text("In this group: all **\(group.photos.count)** will be deleted, **0** kept").foregroundStyle(.orange)
                    }
                    Spacer()
                    Text("Click a photo to switch between Keep and Delete · Space to view larger").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)

        } else {
            ContentUnavailableView("Select a group", systemImage: "square.stack.3d.up")
        }
    }

    @ViewBuilder private var preview: some View {
        if let group = model.selectedGroup, let id = model.previewPhotoID,
           let index = group.photos.firstIndex(where: { $0.id == id }) {
            let photo = group.photos[index]
            let analysis = model.analyses[group.id]
            PhotoPreview(
                photo: photo,
                position: index + 1,
                count: group.photos.count,
                isMarked: model.isMarked(photo, in: group),
                isRecommended: analysis?.recommended == photo.id,
                details: analysis?.scores[photo.id].map { photoDetails($0, relativeSharpness: analysis?.relativeSharpness[photo.id]) },
                canToggle: analysis != nil,
                close: { model.previewPhotoID = nil },
                toggle: { model.toggle(photo, in: group) }
            )
        }
    }

    private func title(for group: ReviewModel.Group) -> String {
        guard let first = group.photos.first?.taken, let last = group.photos.last?.taken else { return "" }
        let day = first.formatted(date: .abbreviated, time: .omitted)
        let span = last.timeIntervalSince(first)
        let time = first.formatted(date: .omitted, time: .shortened)
        return "\(day) at \(time) · \(group.photos.count) photos over \(span < 1 ? "under a second" : "\(span.formatted(.number.precision(.fractionLength(0...1)))) s")"
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        let s = model.summary
        return VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("**\(s.toDelete.formatted())** will be deleted · **\(s.toKeep.formatted())** will be kept")
                    Text("Reviewed \(s.reviewedGroups.formatted()) of \(model.groups.count.formatted()) groups. Only groups you've opened count.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !s.groupsWithNothingKept.isEmpty {
                    Button {
                        model.selectFirstGroupWithNothingKept()
                    } label: {
                        Label("\(s.groupsWithNothingKept.count) group\(s.groupsWithNothingKept.count == 1 ? "" : "s") with nothing kept", systemImage: "exclamationmark.triangle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                }
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { model.move(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                Button { model.move(1) } label: { Label("Next Group", systemImage: "chevron.right") }
                Button("Move \(s.toDelete.formatted()) to Trash…") { model.confirmingTrash = true }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(s.toDelete == 0 || model.phase == .trashing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var trashTitle: String {
        let n = model.summary.toDelete
        return "Move \(n.formatted()) photo\(n == 1 ? "" : "s") to the Trash?"
    }

    private var trashMessage: String {
        let s = model.summary
        var text = "\(s.toKeep.formatted()) photo\(s.toKeep == 1 ? "" : "s") in the \(s.reviewedGroups.formatted()) reviewed groups will be kept. "
            + "Live Photo videos and edit files that belong to the deleted photos go with them. "
            + "You can put anything back from the Trash until you empty it."
        if !s.groupsWithNothingKept.isEmpty {
            let n = s.groupsWithNothingKept.count
            text += "\n\nWarning: in \(n) group\(n == 1 ? "" : "s") you're deleting every photo, so nothing from \(n == 1 ? "that moment" : "those moments") will be left."
        }
        return text
    }
}

struct GroupRow: View {
    enum Status: Equatable {
        case notReviewed
        case reviewed(deleting: Int, keeping: Int)
        case nothingKept
    }

    let group: ReviewModel.Group
    let status: Status

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(url: group.photos[0].url, maxPixel: 120, fill: true)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(group.photos[0].taken.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
                HStack(spacing: 4) {
                    Text("\(group.photos.count) photos")
                    switch status {
                    case .notReviewed:
                        EmptyView()
                    case .reviewed(let deleting, _):
                        Text("· \(deleting) to delete").foregroundStyle(deleting > 0 ? .red : .secondary)
                    case .nothingKept:
                        Label("nothing kept", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if status != .notReviewed, status != .nothingKept {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PhotoCell: View {
    let photo: ReviewModel.Photo
    let isMarked: Bool
    let isRecommended: Bool
    let isIdenticalCopy: Bool
    let isNew: Bool
    let score: PhotoScore?
    let relativeSharpness: Double?
    let canToggle: Bool
    let toggle: () -> Void
    let hover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailView(url: photo.url, maxPixel: 700, fill: false)
                .frame(height: 210)
                .opacity(isMarked ? 0.35 : 1)
                .overlay {
                    if isMarked {
                        Image(systemName: "trash.fill").font(.system(size: 34)).foregroundStyle(.white).shadow(radius: 4)
                    }
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        if isRecommended { badge("★ Recommended", .green) }
                        if isIdenticalCopy { badge("Identical copy", .gray) }
                        if isNew { badge("New", .blue) }
                    }
                    .padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isMarked ? Color.red : (isRecommended ? Color.green : Color.secondary.opacity(0.25)),
                                      lineWidth: isMarked || isRecommended ? 3 : 1)
                )

            Text(photo.url.lastPathComponent)
                .font(.caption.bold())
                .lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            HStack {
                Text(photo.taken, format: .dateTime.hour().minute().second().secondFraction(.fractional(2)))
                    .font(.caption.monospacedDigit())
                Spacer()
                Label(isMarked ? "Delete" : "Keep", systemImage: isMarked ? "trash" : "checkmark.circle.fill")
                    .font(.caption.bold())
                    .foregroundStyle(isMarked ? .red : .green)
            }
            if let score {
                Text(photoDetails(score, relativeSharpness: relativeSharpness)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if canToggle { toggle() } }
        .onHover(perform: hover)
        .contextMenu {
            Button("Open in Preview") { NSWorkspace.shared.open(photo.url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([photo.url]) }
        }
        .help(photo.id)
    }

    private func badge(_ text: String, _ color: Color) -> some View { Badge(text: text, color: color) }
}

/// Full-window view of one photo. Keys (Space/Esc, ← →, D) are handled by `ReviewModel.handleKey`.
struct PhotoPreview: View {
    let photo: ReviewModel.Photo
    let position: Int
    let count: Int
    let isMarked: Bool
    let isRecommended: Bool
    let details: String?
    let canToggle: Bool
    let close: () -> Void
    let toggle: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).onTapGesture(perform: close)
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    if isRecommended { Badge(text: "★ Recommended", color: .green) }
                    Text(photo.url.lastPathComponent).bold().textSelection(.enabled)
                    Text(photo.taken, format: .dateTime.hour().minute().second().secondFraction(.fractional(2)))
                        .monospacedDigit()
                    Text("\(position) of \(count)").foregroundStyle(.white.opacity(0.6))
                    if let details { Text(details).foregroundStyle(.white.opacity(0.6)) }
                    Spacer()
                    Button(action: toggle) {
                        Label(isMarked ? "Delete" : "Keep", systemImage: isMarked ? "trash.fill" : "checkmark.circle.fill")
                    }
                    .tint(isMarked ? .red : .green)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canToggle)
                    .help("Switch between Keep and Delete (D)")
                    Button(action: close) { Image(systemName: "xmark") }
                        .help("Close (Space or Esc)")
                }
                .font(.callout)
                .foregroundStyle(.white)

                ThumbnailView(url: photo.url, maxPixel: 2400, fill: false, background: .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(isMarked ? Color.red : .clear, lineWidth: 4)
                    )

                Text("← → other photos in this group  ·  D keep/delete  ·  Space or Esc to close")
                    .font(.caption).foregroundStyle(.white.opacity(0.6))
            }
            .padding(24)
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }
}

func photoDetails(_ score: PhotoScore, relativeSharpness: Double?) -> String {
    var parts: [String] = []
    if let relativeSharpness { parts.append("Sharpness \(Int((relativeSharpness * 100).rounded()))%") }
    if score.faces > 0 { parts.append("Eyes open \(score.facesWithEyesOpen)/\(score.faces)") }
    if let tilt = score.tiltDegrees { parts.append("Tilt \(abs(tilt).formatted(.number.precision(.fractionLength(1))))°") }
    return parts.joined(separator: " · ")
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
