import XCTest
@testable import XIVKRLauncher

final class ExternalLinkTests: XCTestCase {
    func testAllowsHTTPSExternalLinks() {
        XCTAssertEqual(
            externalBrowserURL(URL(string: "https://www.youtube.com/watch?v=abc"))?.absoluteString,
            "https://www.youtube.com/watch?v=abc"
        )
    }

    func testUpgradesOfficialHTTPLinks() {
        XCTAssertEqual(
            externalBrowserURL(URL(string: "http://guide.ff14.co.kr/path"))?.absoluteString,
            "https://guide.ff14.co.kr/path"
        )
    }

    func testRejectsUnsafeSchemesHostsAndCredentials() {
        XCTAssertNil(externalBrowserURL(URL(string: "javascript:alert(1)")))
        XCTAssertNil(externalBrowserURL(URL(string: "http://example.com/")))
        XCTAssertNil(externalBrowserURL(URL(string: "https://user:pass@example.com/")))
        XCTAssertNil(externalBrowserURL(URL(string: "https://example.com:8443/")))
    }
}
