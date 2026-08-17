import Foundation
import XCTest
@testable import XIVKRLauncher

final class LivePatchFixtureTests: XCTestCase {
    func testLivePatchFixtureWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["XIVKR_PATCH_FIXTURE"] else {
            throw XCTSkip("XIVKR_PATCH_FIXTURE is not set")
        }
        let patches = try parseOfficialPatchList(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertFalse(patches.isEmpty)
        XCTAssertTrue(patches.contains { $0.repository == .game })

        let current: [PatchRepository: String] = [
            .game: "2026.05.25.0000.0000",
            .ex1: "2026.05.15.0000.0000",
            .ex2: "2026.05.25.0000.0000",
            .ex3: "2026.05.25.0000.0000",
            .ex4: "2026.05.25.0000.0000",
            .ex5: "2026.05.25.0000.0000",
        ]
        let plan = try officialPatchPlan(
            patches: patches,
            current: current,
            requestedBaseVersion: current[.game]
        )
        XCTAssertTrue(plan.hasUpdates)
        XCTAssertNotEqual(plan.latestGameVersion, "-")
    }
}
