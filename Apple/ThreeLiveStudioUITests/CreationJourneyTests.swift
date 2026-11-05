import XCTest

@MainActor
final class CreationJourneyTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testCreateSaveReopenAndExport() throws {
        let app = XCUIApplication()
        app.launch()
        let generate = app.buttons["generateParameters"]
        XCTAssertTrue(generate.waitForExistence(timeout: 10))
        generate.tap()
        let export = app.buttons["exportMenu"]
        // The compact workspace intentionally scrolls: every control must remain reachable.
        for _ in 0..<5 where !export.isHittable { app.swipeUp() }
        XCTAssertTrue(export.waitForExistence(timeout: 15))
        XCTAssertTrue(export.isEnabled)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "created-building"; attachment.lifetime = .keepAlways; add(attachment)
        export.tap()
        XCTAssertTrue(app.buttons["导出 USDZ"].waitForExistence(timeout: 3))
        app.buttons["导出 USDZ"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 3) || app.buttons["Copy"].exists || app.buttons["拷贝"].exists)
        app.terminate()
        app.launch()
        app.tabBars.buttons["作品"].tap()
        let item = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "自由造型")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        item.tap()
        for _ in 0..<5 where !app.buttons["exportMenu"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["exportMenu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["exportMenu"].isEnabled)
    }

    func testModelTabAndAccessibleCreationControls() {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["generateParameters"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["generateParameters"].isHittable)
        app.tabBars.buttons["本机模型"].tap()
        XCTAssertTrue(app.staticTexts["modelStatus"].waitForExistence(timeout: 5))
    }
}
