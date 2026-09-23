import XCTest
@testable import PhotoImportCore

final class LibraryLayoutTests: XCTestCase {
    func testMonthFolder() {
        XCTAssertEqual(LibraryLayout.folder(for: date(2026, 9, 23)), "2026/09-2026")
        XCTAssertEqual(LibraryLayout.folder(for: date(2019, 1, 1, 0, 0, 1)), "2019/01-2019")
    }

    func testSidecarNameFollowsRenamedPhoto() {
        XCTAssertEqual(LibraryLayout.sidecarName("IMG_1.MOV", originalMain: "IMG_1.HEIC", savedMain: "IMG_1 1.HEIC"), "IMG_1 1.MOV")
        XCTAssertEqual(LibraryLayout.sidecarName("IMG_O1.AAE", originalMain: "IMG_1.HEIC", savedMain: "IMG_1 2.HEIC"), "IMG_O1 2.AAE")
        XCTAssertEqual(LibraryLayout.sidecarName("IMG_1.MOV", originalMain: "IMG_1.HEIC", savedMain: "IMG_1.HEIC"), "IMG_1.MOV")
        XCTAssertEqual(LibraryLayout.sidecarName("OTHER.MOV", originalMain: "IMG_1.HEIC", savedMain: "IMG_1 1.HEIC"), "OTHER.MOV")
    }
}

final class PhotoLibraryTests: TempDirTestCase {
    func testIngestSortsIntoMonthFolder() throws {
        let lib = PhotoLibrary(root: dir)
        let tmp = try write("in/a.heic", bytes("A"))
        let r = try lib.ingest(tmp, name: "IMG_1.HEIC", date: date(2025, 7, 4))
        XCTAssertEqual(r, .imported(path: "2025/07-2025/IMG_1.HEIC", sha: try FileHasher.sha256(of: dir.appendingPathComponent(r.path))))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path), "downloaded file is moved, not copied")
    }

    func testSameContentIsNotCopiedTwice() throws {
        let lib = PhotoLibrary(root: dir)
        _ = try lib.ingest(try write("in/1", bytes("same")), name: "IMG_1.HEIC", date: date(2025, 7, 4))
        let second = try lib.ingest(try write("in/2", bytes("same")), name: "IMG_9.HEIC", date: date(2026, 1, 1))
        XCTAssertEqual(second.path, "2025/07-2025/IMG_1.HEIC")
        guard case .duplicate = second else { return XCTFail("expected duplicate") }
        XCTAssertEqual(files().filter { !$0.hasPrefix("in/") }, ["2025/07-2025/IMG_1.HEIC"])
    }

    func testSameNameDifferentContentGetsSuffix() throws {
        let lib = PhotoLibrary(root: dir)
        _ = try lib.ingest(try write("in/1", bytes("one")), name: "IMG_1.HEIC", date: date(2025, 7, 4))
        let r = try lib.ingest(try write("in/2", bytes("two")), name: "IMG_1.HEIC", date: date(2025, 7, 5))
        XCTAssertEqual(r.path, "2025/07-2025/IMG_1 1.HEIC")
    }

    func testRefreshFindsExistingFilesAndIsCachedAcrossLaunches() throws {
        _ = try write("2024/12-2024/old.jpg", bytes("old photo"))
        let lib = PhotoLibrary(root: dir)
        try lib.refresh()
        XCTAssertEqual(lib.fileCount, 1)

        // A new launch sees the cache, and still dedupes against the existing file.
        let again = PhotoLibrary(root: dir)
        let r = try again.ingest(try write("in/x", bytes("old photo")), name: "copy.jpg", date: date(2026, 1, 1))
        XCTAssertEqual(r.path, "2024/12-2024/old.jpg")
    }

    func testRefreshNoticesDeletedFiles() throws {
        let existing = try write("2024/12-2024/old.jpg", bytes("old photo"))
        let lib = PhotoLibrary(root: dir)
        try lib.refresh()
        try FileManager.default.removeItem(at: existing)
        try lib.refresh()
        let r = try lib.ingest(try write("in/x", bytes("old photo")), name: "old.jpg", date: date(2026, 1, 1))
        guard case .imported = r else { return XCTFail("file was deleted, so it should be imported again") }
    }
}
