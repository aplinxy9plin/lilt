import XCTest

final class UpdateCheckerTests: XCTestCase {
    func testSparkleConfigurationIsSecureAndAutomatic() throws {
        let plist = try loadAppInfoPlist()

        XCTAssertEqual(
            plist["SUFeedURL"] as? String,
            "https://github.com/aplinxy9plin/lilt/releases/latest/download/appcast.xml"
        )
        XCTAssertEqual(plist["SUEnableAutomaticChecks"] as? Bool, true)
        XCTAssertEqual(plist["SUAllowsAutomaticUpdates"] as? Bool, true)
        XCTAssertEqual(plist["SUAutomaticallyUpdate"] as? Bool, true)
        XCTAssertEqual(plist["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(plist["SURequireSignedFeed"] as? Bool, true)

        let publicKey = try XCTUnwrap(plist["SUPublicEDKey"] as? String)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
    }

    private func loadAppInfoPlist() throws -> [String: Any] {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let plistURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("BitChordMac/Info.plist")
        let data = try Data(contentsOf: plistURL)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
    }
}
