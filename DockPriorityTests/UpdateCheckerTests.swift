import XCTest
@testable import DockPriority

final class UpdateCheckerTests: XCTestCase {
    func testAllowsProjectLatestReleaseURL() {
        let url = URL(string: "https://github.com/cinestill-800T/DockPriority/releases/latest")!

        XCTAssertTrue(ReleaseURLPolicy.isAllowed(url))
        XCTAssertEqual(ReleaseURLPolicy.normalizedReleaseURL(rawValue: url.absoluteString), url)
    }

    func testAllowsProjectTaggedReleaseURL() {
        let url = URL(string: "https://github.com/cinestill-800T/DockPriority/releases/tag/v0.1.0")!

        XCTAssertTrue(ReleaseURLPolicy.isAllowed(url))
        XCTAssertEqual(ReleaseURLPolicy.normalizedReleaseURL(rawValue: url.absoluteString), url)
    }

    func testRejectsHostileOrMalformedReleaseURLs() {
        let hostileURLs = [
            "http://github.com/cinestill-800T/DockPriority/releases/latest",
            "https://evil.example/cinestill-800T/DockPriority/releases/latest",
            "https://github.com/other-user/DockPriority/releases/latest",
            "https://github.com/cinestill-800T/other-repo/releases/latest",
            "https://github.com/cinestill-800T/DockPriority/issues",
            "https://attacker@github.com/cinestill-800T/DockPriority/releases/latest",
            "https://github.com:443/cinestill-800T/DockPriority/releases/latest",
            "https://github.com/cinestill-800T/DockPriority/releases/tag/",
            "not a URL"
        ]

        for rawURL in hostileURLs {
            XCTAssertEqual(
                ReleaseURLPolicy.normalizedReleaseURL(rawValue: rawURL),
                ReleaseURLPolicy.fallbackURL,
                "Expected fallback for \(rawURL)"
            )
        }
    }
}
