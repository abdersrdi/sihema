import XCTest

/// Opens every real-world G-code file found in the folder named by CORPUS_DIR and keeps a screenshot of the
/// toolpath and of the simulated report for each. Skipped when CORPUS_DIR is not set.
final class RealFileTests: XCTestCase {
    func testCorpus() throws {
        guard let dir = ProcessInfo.processInfo.environment["CORPUS_DIR"] else {
            throw XCTSkip("CORPUS_DIR is not set")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir).sorted().filter { !$0.hasPrefix(".") }
        XCTAssertFalse(files.isEmpty)
        continueAfterFailure = true
        for file in files {
            for (tab, simulate) in [("path", false), ("report", true)] {
                let app = XCUIApplication()
                var environment = ["SIHEMA_UITEST": "1", "SIHEMA_TAB": tab, "SIHEMA_PROGRAM": dir + "/" + file]
                if simulate { environment["SIHEMA_SIMULATE"] = "1" }
                app.launchEnvironment = environment
                app.launch()
                sleep(simulate ? 8 : 4)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "\(file)-\(tab)"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }
}
