import XCTest

final class TimenBarUITests: XCTestCase {
    func testAccessoryAppLaunches() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10) || app.state == .runningBackground)
    }
}
