import XCTest
@testable import HwpStudio

final class AppLaunchTests: XCTestCase {
    func testAppMetadata() {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.bundleIdentifier, "app.hwpstudio.mac")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String, "14.0")
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        XCTAssertFalse((name ?? "").isEmpty)
    }
}
