import Combine
import XCTest
@testable import DockPriority

@MainActor
final class AppSettingsTests: XCTestCase {
    func testMenuBarVisibilityWriteBackIgnoresSameValuesAndDefersOneRealChange() async {
        let suiteName = "DockPriorityTests.AppSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "showStatusIcon")
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults, sideEffectsEnabled: false)
        var publicationCount = 0
        let observation = settings.objectWillChange.sink { publicationCount += 1 }
        defer { observation.cancel() }

        settings.requestMenuBarIconVisibility(true)
        settings.requestMenuBarIconVisibility(true)
        await Task.yield()

        XCTAssertEqual(publicationCount, 0)
        XCTAssertTrue(settings.showStatusIcon)

        settings.requestMenuBarIconVisibility(false)
        settings.requestMenuBarIconVisibility(false)

        XCTAssertEqual(publicationCount, 0)
        XCTAssertTrue(settings.showStatusIcon, "The real update must be deferred")

        await Task.yield()

        XCTAssertEqual(publicationCount, 1)
        XCTAssertFalse(settings.showStatusIcon)
        XCTAssertFalse(defaults.bool(forKey: "showStatusIcon"))

        settings.requestMenuBarIconVisibility(false)
        settings.requestMenuBarIconVisibility(false)
        await Task.yield()

        XCTAssertEqual(publicationCount, 1)
    }
}
