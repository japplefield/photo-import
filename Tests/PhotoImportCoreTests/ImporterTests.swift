import XCTest
@testable import PhotoImportCore

/// The delete-from-iPhone gating is the riskiest part of the app, so it's covered from every angle here.
final class ImporterTests: TempDirTestCase {
    func testWithoutDeleterNothingIsDeleted() async throws {
        let lib = PhotoLibrary(root: dir)
        let stats = await Importer(library: lib).run([ImportItem(main: FakeFile("IMG_1.HEIC", bytes("a")))])
        XCTAssertEqual(stats.imported, 1)
        XCTAssertEqual(stats.deleted, 0)
        XCTAssertEqual(files(), ["2026/09-2026/IMG_1.HEIC"])
    }

    func testDeletesOnlyAfterCopyAndMatchingSecondRead() async throws {
        let recorder = DeleteRecorder()
        let file = FakeFile("IMG_1.HEIC", bytes("a"))
        let stats = await Importer(library: PhotoLibrary(root: dir), deleter: recorder.deleter()).run([ImportItem(main: file)])
        XCTAssertEqual(recorder.deleted, ["IMG_1.HEIC"])
        XCTAssertEqual(stats.deleted, 1)
        XCTAssertEqual(file.downloads, 2, "copy + independent verification read")
    }

    func testSecondReadMismatchBlocksDelete() async throws {
        let recorder = DeleteRecorder()
        let flaky = FakeFile("IMG_1.HEIC", bytes("aaaa"), laterReads: [bytes("aaab")])
        let stats = await Importer(library: PhotoLibrary(root: dir), deleter: recorder.deleter()).run([ImportItem(main: flaky)])
        XCTAssertEqual(recorder.deleted, [])
        XCTAssertEqual(stats.failed, 1)
    }

    func testSizeMismatchBlocksCopyAndDelete() async throws {
        let recorder = DeleteRecorder()
        let short = FakeFile("IMG_1.HEIC", bytes("abc"), reportedSize: 10)
        let stats = await Importer(library: PhotoLibrary(root: dir), deleter: recorder.deleter()).run([ImportItem(main: short)])
        XCTAssertEqual(recorder.deleted, [])
        XCTAssertEqual(stats.failed, 1)
        XCTAssertEqual(files(), [], "partial download never lands in the library")
    }

    func testFailedDownloadBlocksDelete() async throws {
        let recorder = DeleteRecorder()
        let broken = FakeFile("IMG_1.HEIC", bytes("a"))
        broken.failDownloads = true
        _ = await Importer(library: PhotoLibrary(root: dir), deleter: recorder.deleter()).run([ImportItem(main: broken)])
        XCTAssertEqual(recorder.deleted, [])
    }

    func testFailedSidecarBlocksDeletingThePhoto() async throws {
        let recorder = DeleteRecorder()
        let video = FakeFile("IMG_1.MOV", bytes("live"))
        video.failDownloads = true
        let item = ImportItem(main: FakeFile("IMG_1.HEIC", bytes("photo")), sidecars: [video])
        _ = await Importer(library: PhotoLibrary(root: dir), deleter: recorder.deleter()).run([item])
        XCTAssertEqual(recorder.deleted, [], "a Live Photo is only deleted when its video was copied too")
    }

    func testAlreadyInLibraryIsNotCopiedButCanBeDeleted() async throws {
        _ = try write("2026/09-2026/IMG_1.HEIC", bytes("a"))
        let lib = PhotoLibrary(root: dir)
        try lib.refresh()
        let recorder = DeleteRecorder()
        let stats = await Importer(library: lib, deleter: recorder.deleter()).run([ImportItem(main: FakeFile("IMG_1.HEIC", bytes("a")))])
        XCTAssertEqual(stats.alreadyInLibrary, 1)
        XCTAssertEqual(stats.imported, 0)
        XCTAssertEqual(recorder.deleted, ["IMG_1.HEIC"], "content is safely in the library already")
        XCTAssertEqual(files(), ["2026/09-2026/IMG_1.HEIC"])
    }

    func testDeleteFailureIsReportedAndImportContinues() async throws {
        let recorder = DeleteRecorder()
        recorder.fail = true
        let items = [ImportItem(main: FakeFile("A.HEIC", bytes("a"))), ImportItem(main: FakeFile("B.HEIC", bytes("b")))]
        let stats = await Importer(library: PhotoLibrary(root: dir), deleter: recorder.deleter()).run(items)
        XCTAssertEqual(stats.imported, 2)
        XCTAssertEqual(stats.deleteFailed, 2)
    }

    func testLivePhotoPartsStayTogetherWhenRenamed() async throws {
        _ = try write("2026/09-2026/IMG_1.HEIC", bytes("a different photo"))
        let item = ImportItem(main: FakeFile("IMG_1.HEIC", bytes("photo")), sidecars: [FakeFile("IMG_1.MOV", bytes("video"))])
        _ = await Importer(library: PhotoLibrary(root: dir)).run([item])
        XCTAssertEqual(files(), ["2026/09-2026/IMG_1 1.HEIC", "2026/09-2026/IMG_1 1.MOV", "2026/09-2026/IMG_1.HEIC"])
    }

    func testStopLeavesRemainingItemsAlone() async throws {
        let recorder = DeleteRecorder()
        let importer = Importer(library: PhotoLibrary(root: dir), deleter: recorder.deleter())
        var processed = 0
        importer.onStats = { processed = $0.processed }
        importer.isCancelled = { processed >= 1 }
        let items = ["A", "B", "C"].map { ImportItem(main: FakeFile("\($0).HEIC", bytes($0))) }
        let stats = await importer.run(items)
        XCTAssertEqual(stats.processed, 1)
        XCTAssertEqual(recorder.deleted, ["A.HEIC"])
    }
}
