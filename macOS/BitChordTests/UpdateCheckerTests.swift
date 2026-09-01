import XCTest

final class UpdateCheckerTests: XCTestCase {
    func testReleasePrefixAndMissingPatchAreEquivalent() {
        XCTAssertEqual(ReleaseVersion("v1.2.0"), ReleaseVersion("1.2"))
    }

    func testNumericComponentsUseSemanticOrdering() {
        XCTAssertLessThan(ReleaseVersion("1.9.0")!, ReleaseVersion("1.10.0")!)
        XCTAssertLessThan(ReleaseVersion("0.1.0")!, ReleaseVersion("0.2.0")!)
    }

    func testStableReleaseWinsOverPrerelease() {
        XCTAssertLessThan(ReleaseVersion("2.0.0-beta.2")!, ReleaseVersion("2.0.0")!)
        XCTAssertLessThan(ReleaseVersion("2.0.0-beta.2")!, ReleaseVersion("2.0.0-beta.10")!)
    }

    func testMalformedTagsAreRejected() {
        XCTAssertNil(ReleaseVersion("latest"))
        XCTAssertNil(ReleaseVersion("v1..2"))
    }
}
