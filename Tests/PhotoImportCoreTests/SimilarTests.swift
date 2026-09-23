import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PhotoImportCore

final class SimilarGrouperTests: XCTestCase {
    func ref(_ name: String, _ seconds: Double) -> PhotoRef {
        PhotoRef(path: name, taken: date(2026, 9, 3, 12, 0, 0).addingTimeInterval(seconds))
    }

    func testBurstsSplitOnGaps() {
        let photos = [ref("a", 0), ref("b", 0.4), ref("c", 1.5), ref("lonely", 30), ref("d", 60), ref("e", 61)]
        let groups = SimilarGrouper.groups(photos.shuffled(), maxGap: 2).map { $0.map(\.path) }
        XCTAssertEqual(groups, [["a", "b", "c"], ["d", "e"]])
    }

    func testSingletonsAreNotGroups() {
        XCTAssertEqual(SimilarGrouper.groups([ref("a", 0), ref("b", 10)], maxGap: 2).count, 0)
    }

    func testGapIsConfigurable() {
        let photos = [ref("a", 0), ref("b", 4)]
        XCTAssertEqual(SimilarGrouper.groups(photos, maxGap: 2).count, 0)
        XCTAssertEqual(SimilarGrouper.groups(photos, maxGap: 5).count, 1)
    }
}

final class RecommenderTests: XCTestCase {
    func testPrefersEyesOpenOverSlightlySharperBlink() {
        let blink = PhotoScore(sharpness: 100, faces: 2, facesWithEyesOpen: 1, faceQuality: 0.6)
        let open = PhotoScore(sharpness: 90, faces: 2, facesWithEyesOpen: 2, faceQuality: 0.6)
        let r = Recommender.recommend([blink, open])!
        XCTAssertEqual(r.best, 1)
        XCTAssertTrue(r.reasons.contains("Eyes open"))
    }

    func testPrefersSharpWhenNoPeople() {
        let blurry = PhotoScore(sharpness: 20, tiltDegrees: 0)
        let sharp = PhotoScore(sharpness: 200, tiltDegrees: 0)
        let r = Recommender.recommend([blurry, sharp])!
        XCTAssertEqual(r.best, 1)
        XCTAssertEqual(r.reasons, ["Sharpest", "Level"])
    }

    func testPenalizesTilt() {
        let tilted = PhotoScore(sharpness: 100, tiltDegrees: 8)
        let level = PhotoScore(sharpness: 97, tiltDegrees: 0.3)
        XCTAssertEqual(Recommender.recommend([tilted, level])!.best, 1)
    }

    func testFaceMissingCountsAgainstPhotoInGroupWithPeople() {
        let turnedAway = PhotoScore(sharpness: 100, faces: 0)
        let facing = PhotoScore(sharpness: 90, faces: 1, facesWithEyesOpen: 1)
        XCTAssertEqual(Recommender.recommend([turnedAway, facing])!.best, 1)
    }

    func testTieGoesToFirst() {
        let s = PhotoScore(sharpness: 50)
        XCTAssertEqual(Recommender.recommend([s, s, s])!.best, 0)
    }

    func testEmpty() { XCTAssertNil(Recommender.recommend([])) }
}

final class ReviewSelectionTests: XCTestCase {
    let group = ReviewGroup(id: 1, paths: ["a", "b", "c"])
    let other = ReviewGroup(id: 2, paths: ["x", "y"])

    func testOpeningKeepsRecommendedAndMarksRest() {
        var sel = ReviewSelection()
        sel.open(group, recommended: "b")
        XCTAssertEqual(sel.markedPaths(in: group), ["a", "c"])
        let s = sel.summary(of: [group, other])
        XCTAssertEqual(s.toDelete, 2)
        XCTAssertEqual(s.toKeep, 1)
        XCTAssertEqual(s.reviewedGroups, 1, "unopened groups never count")
    }

    func testOpeningTwiceKeepsUserChoices() {
        var sel = ReviewSelection()
        sel.open(group, recommended: "b")
        sel.toggle("a", in: group)
        sel.open(group, recommended: "b")
        XCTAssertEqual(sel.markedPaths(in: group), ["c"])
    }

    func testWarnsWhenEverythingInAGroupIsMarked() {
        var sel = ReviewSelection()
        sel.open(group, recommended: "b")
        sel.toggle("b", in: group)
        XCTAssertEqual(sel.summary(of: [group]).groupsWithNothingKept, [1])
        sel.toggle("c", in: group)
        XCTAssertEqual(sel.summary(of: [group]).groupsWithNothingKept, [])
    }

    func testKeepAllAndKeepOnly() {
        var sel = ReviewSelection()
        sel.open(group, recommended: nil)
        XCTAssertEqual(sel.markedPaths(in: group), [], "no recommendation yet → nothing marked")
        sel.keepOnly("c", in: group)
        XCTAssertEqual(sel.markedPaths(in: group), ["a", "b"])
        sel.keepAll(group)
        XCTAssertEqual(sel.summary(of: [group]).toKeep, 3)
    }
}

final class SidecarTests: TempDirTestCase {
    func testEditFilesGoWithTheirPhoto() async throws {
        let photo = try write("IMG_5 1.HEIC", bytes("p"))
        _ = try write("IMG_5 1.AAE", bytes("e"))
        _ = try write("IMG_O5 1.AAE", bytes("o"))
        _ = try write("IMG_5.AAE", bytes("someone else's"))
        let found = await Sidecars.find(for: photo).map(\.lastPathComponent).sorted()
        XCTAssertEqual(found, ["IMG_5 1.AAE", "IMG_O5 1.AAE"])
    }

    func testAmbiguousEditFilesAreLeftAlone() async throws {
        let photo = try write("IMG_5.HEIC", bytes("p"))
        _ = try write("IMG_5.JPG", bytes("another photo with the same name"))
        _ = try write("IMG_5.AAE", bytes("e"))
        let found = await Sidecars.find(for: photo)
        XCTAssertEqual(found, [])
    }

    func testSameNamedVideoWithoutMatchingLivePhotoIDIsLeftAlone() async throws {
        let photo = try write("IMG_7.HEIC", bytes("p"))
        _ = try write("IMG_7.MOV", bytes("a separate video"))
        let found = await Sidecars.find(for: photo)
        XCTAssertEqual(found, [])
    }

    func testMoveToTrashTakesSidecarsButNotWhenPhotoFails() async throws {
        let ok = try write("A.HEIC", bytes("a"))
        _ = try write("A.AAE", bytes("ae"))
        let stuck = try write("B.HEIC", bytes("b"))
        _ = try write("B.AAE", bytes("be"))
        var trashed: [String] = []
        let result = await LibraryCleanup.moveToTrash([ok, stuck]) { url in
            if url.lastPathComponent == "B.HEIC" { throw CocoaError(.fileWriteNoPermission) }
            trashed.append(url.lastPathComponent)
        }
        XCTAssertEqual(trashed, ["A.HEIC", "A.AAE"])
        XCTAssertEqual(result.photos.count, 1)
        XCTAssertEqual(result.failures.count, 1)
    }
}

final class ImageAnalysisTests: TempDirTestCase {
    func checkerboard(cell: Int, size: Int = 800) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        for y in stride(from: 0, to: size, by: cell) {
            for x in stride(from: 0, to: size, by: cell) where (x / cell + y / cell) % 2 == 0 {
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return ctx.makeImage()!
    }

    /// Same pattern, but rendered tiny and scaled up, i.e. out of focus.
    func blurred(_ image: CGImage) -> CGImage {
        let small = CGContext(data: nil, width: 40, height: 40, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0, width: 40, height: 40))
        let big = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        big.interpolationQuality = .high
        big.draw(small.makeImage()!, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return big.makeImage()!
    }

    func testSharpScoresHigherThanBlurred() {
        let sharp = checkerboard(cell: 16)
        XCTAssertGreaterThan(PhotoScorer.sharpness(of: sharp), 5 * PhotoScorer.sharpness(of: blurred(sharp)))
    }

    func testScoringRunsOnARealImageFile() throws {
        let url = dir.appendingPathComponent("test.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, checkerboard(cell: 20), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let score = try PhotoScorer.score(url: url)
        XCTAssertGreaterThan(score.sharpness, 0)
        XCTAssertEqual(score.faces, 0)
    }

    func testCaptureDateReadsExifWithSubseconds() throws {
        let url = dir.appendingPathComponent("dated.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        let exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: "2025:07:04 21:30:15",
            kCGImagePropertyExifSubsecTimeOriginal: "25",
        ]
        CGImageDestinationAddImage(dest, checkerboard(cell: 20, size: 64), [kCGImagePropertyExifDictionary: exif] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let taken = try XCTUnwrap(CaptureDate.imageDate(url))
        XCTAssertEqual(taken.timeIntervalSince1970, date(2025, 7, 4, 21, 30, 15.25).timeIntervalSince1970, accuracy: 0.001)
    }
}

final class ImportThenReviewTests: TempDirTestCase {
    func testImporterReportsOnlyNewlyCopiedPaths() async throws {
        _ = try write("2026/09-2026/OLD.HEIC", bytes("old"))
        let lib = PhotoLibrary(root: dir)
        try lib.refresh()
        let importer = Importer(library: lib)
        _ = await importer.run([
            ImportItem(main: FakeFile("OLD.HEIC", bytes("old"))),
            ImportItem(main: FakeFile("NEW.HEIC", bytes("new")), sidecars: [FakeFile("NEW.MOV", bytes("mov"))]),
        ])
        XCTAssertEqual(importer.importedPaths, ["2026/09-2026/NEW.HEIC", "2026/09-2026/NEW.MOV"])
    }

    func testFilterKeepsWholeGroupsThatTouchNewPhotos() {
        let t = date(2026, 9, 3)
        let photos = [
            PhotoRef(path: "old1", taken: t), PhotoRef(path: "new1", taken: t.addingTimeInterval(1)),
            PhotoRef(path: "old2", taken: t.addingTimeInterval(60)), PhotoRef(path: "old3", taken: t.addingTimeInterval(61)),
        ]
        let groups = SimilarGrouper.groups(photos, maxGap: 2, including: ["new1"]).map { $0.map(\.path) }
        XCTAssertEqual(groups, [["old1", "new1"]])
    }
}

final class ReviewKeysTests: XCTestCase {
    func action(_ key: ReviewKey, _ index: Int?, of count: Int = 3) -> ReviewAction {
        ReviewKeys.action(for: key, previewIndex: index, photoCount: count)
    }

    func testPreviewStepsBackAndForth() {
        XCTAssertEqual(action(.right, 0), .showPhoto(1))
        XCTAssertEqual(action(.right, 1), .showPhoto(2))
        XCTAssertEqual(action(.left, 2), .showPhoto(1))
        XCTAssertEqual(action(.left, 1), .showPhoto(0))
    }

    func testPreviewStopsAtEnds() {
        XCTAssertEqual(action(.left, 0), .none)
        XCTAssertEqual(action(.right, 2), .none)
    }

    func testArrowsMoveBetweenGroupsWhenPreviewClosed() {
        XCTAssertEqual(action(.left, nil), .previousGroup)
        XCTAssertEqual(action(.right, nil), .nextGroup)
    }

    func testSpaceOpensAndCloses() {
        XCTAssertEqual(action(.space, nil), .openPreview)
        XCTAssertEqual(action(.space, 1), .closePreview)
        XCTAssertEqual(action(.escape, 1), .closePreview)
        XCTAssertEqual(action(.escape, nil), .none)
    }

    func testToggleOnlyInPreview() {
        XCTAssertEqual(action(.toggle, 1), .toggleCurrent)
        XCTAssertEqual(action(.toggle, nil), .none)
    }
}
