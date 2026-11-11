import XCTest

/// Launches the app on each tab with a sample program and keeps a screenshot of every one.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func capture(_ name: String, tab: String, extra: [String] = [], wait: UInt32 = 5) {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestDirect", "-UITestTab", tab] + extra
        app.launch()
        sleep(wait)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testCode() { capture("01-code", tab: "code") }
    func testPath() { capture("02-path", tab: "path") }
    func testCompare() { capture("03-compare", tab: "compare") }
    func testReport() { capture("04-report", tab: "report") }
    func testReportWithSimulation() { capture("05-report-simulation", tab: "report", extra: ["-UITestSimulate"], wait: 9) }
}
