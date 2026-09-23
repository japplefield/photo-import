import XCTest
@testable import PhotoImportCore

final class DuplicatesTests: TempDirTestCase {
    func testPreferredCopyIsTheOneWithoutSuffix() {
        XCTAssertEqual(Duplicates.preferredOrder(["2026/09-2026/IMG_1 1.HEIC", "2026/09-2026/IMG_1.HEIC"]).first,
                       "2026/09-2026/IMG_1.HEIC")
        XCTAssertEqual(Duplicates.preferredOrder(["a/long/path/X.JPG", "b/X.JPG"]).first, "b/X.JPG")
    }

    func testFindsOnlyIdenticalContent() throws {
        _ = try write("2026/09-2026/IMG_1.HEIC", bytes("same"))
        _ = try write("2026/09-2026/IMG_1 1.HEIC", bytes("same"))
        _ = try write("2025/01-2025/IMG_1.HEIC", bytes("different photo, same name"))
        let lib = PhotoLibrary(root: dir)
        try lib.refresh()
        let sets = lib.duplicateSets()
        XCTAssertEqual(sets.map(\.paths), [["2026/09-2026/IMG_1.HEIC", "2026/09-2026/IMG_1 1.HEIC"]])
    }

    func testRemovesExtrasButAlwaysKeepsOneCopy() throws {
        _ = try write("a/X.HEIC", bytes("same"))
        _ = try write("b/X 1.HEIC", bytes("same"))
        _ = try write("c/X 2.HEIC", bytes("same"))
        let lib = PhotoLibrary(root: dir)
        try lib.refresh()
        var trashed: [String] = []
        let result = Duplicates.removeExtras(lib.duplicateSets(), root: dir) { url in
            trashed.append(url.lastPathComponent)
            try FileManager.default.removeItem(at: url)
        }
        XCTAssertEqual(Set(trashed), ["X 1.HEIC", "X 2.HEIC"])
        XCTAssertEqual(result.removed.count, 2)
        XCTAssertEqual(files(), ["a/X.HEIC"])
    }

    func testUserChosenKeeperIsKept() throws {
        _ = try write("a/X.HEIC", bytes("same"))
        _ = try write("b/X 1.HEIC", bytes("same"))
        let lib = PhotoLibrary(root: dir)
        try lib.refresh()
        let set = try XCTUnwrap(lib.duplicateSets().first)
        _ = Duplicates.removeExtras([set], keep: [set.id: "b/X 1.HEIC"], root: dir) { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(files(), ["b/X 1.HEIC"])
    }

    func testFileChangedSinceScanIsLeftAlone() throws {
        _ = try write("a/X.HEIC", bytes("same"))
        let changed = try write("b/X 1.HEIC", bytes("same"))
        let lib = PhotoLibrary(root: dir)
        try lib.refresh()
        let sets = lib.duplicateSets()
        try bytes("edited since the scan").write(to: changed)
        let result = Duplicates.removeExtras(sets, root: dir) { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(result.removed, [])
        XCTAssertEqual(result.skipped, ["b/X 1.HEIC"])
        XCTAssertEqual(files().count, 2)
    }

    func testKeeperChangedSinceScanMeansNothingIsRemoved() throws {
        let keeper = try write("a/X.HEIC", bytes("same"))
        _ = try write("b/X 1.HEIC", bytes("same"))
        let lib = PhotoLibrary(root: dir)
        try lib.refresh()
        let sets = lib.duplicateSets()
        try FileManager.default.removeItem(at: keeper)
        let result = Duplicates.removeExtras(sets, root: dir) { try FileManager.default.removeItem(at: $0) }
        XCTAssertEqual(result.removed, [], "the only remaining copy must survive")
        XCTAssertEqual(files(), ["b/X 1.HEIC"])
    }
}
