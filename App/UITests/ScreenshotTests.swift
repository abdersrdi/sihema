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
        // the document app starts with an Open panel; "New Document" opens the sample program
        let newDocument = app.buttons["New Document"]
        if newDocument.waitForExistence(timeout: 20) { newDocument.click() }
        let untitled = app.windows.matching(NSPredicate(format: "title BEGINSWITH 'Untitled'")).firstMatch
        let appeared = untitled.waitForExistence(timeout: 20)
        sleep(wait)
        let info = XCTAttachment(string: "document window appeared: \(appeared)\nwindows: \(app.windows.count)\n\n\(app.debugDescription)")
        info.name = name + "-debug.txt"
        info.lifetime = .keepAlways
        add(info)
        let target = untitled.exists ? untitled : app.windows.firstMatch
        let screenshot = target.exists ? target.screenshot() : app.screenshot()
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
