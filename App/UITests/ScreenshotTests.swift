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

        #if os(macOS)
        app.activate()
        let window = app.windows.firstMatch
        let appeared = window.waitForExistence(timeout: 20)
        sleep(wait)
        // what the test can see, to find out why a window might be missing
        let info = XCTAttachment(string: "window appeared: \(appeared)\nwindows: \(app.windows.count)\n\n\(app.debugDescription)")
        info.name = name + "-debug.txt"
        info.lifetime = .keepAlways
        add(info)
        let screenshot = window.exists ? window.screenshot() : app.screenshot()
        #else
        sleep(wait)
        let screenshot = app.screenshot()
        #endif

        let attachment = XCTAttachment(screenshot: screenshot)
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
