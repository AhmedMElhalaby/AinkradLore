import XCTest
@testable import LoreFeature

final class EngineRegistryTests: XCTestCase {
    private func tempFile(_ name: String, _ contents: String = "") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lore-engine-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func test_registry_hasAtLeastOneEngine() throws {
        try XCTSkipIf(EngineRegistry.engines.isEmpty, "engines land in Tasks 3-4")
        XCTAssertFalse(EngineRegistry.engines.isEmpty)
    }

    func test_registry_returnsNilForUnclaimedType() throws {
        let url = try tempFile("sheet.xlsx", "binary-ish")
        XCTAssertNil(EngineRegistry.engine(for: url))
    }

    func test_engineIdentifiersAreUnique() {
        let ids = EngineRegistry.engines.map { $0.identifier }
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate engine identifiers: \(ids)")
    }
}
