import XCTest

/// UI actions drive the real Google compiler and project store in the App.
/// The explicitly chosen built-in scene is Codex-authored example code, not an
/// AI fallback. The pasted source is a UI/compiler control, not an LLM result.
@MainActor final class SceneStudioUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func test01ExplicitExampleCompilesSavesAndSurvivesColdRelaunch() throws {
        app.launch()
        try startNewWorkingSceneIfNeeded()
        let example = button(identifier: "importExample", label: "看看示例场景")
        XCTAssertTrue(example.waitForExistence(timeout: 10), "The example must be explicitly selected by the user")
        try tapVisible(example)
        try waitForImportedSource()
        let title = try makeUniqueTitle(marker: "UI示例")

        try compileAndSaveOnce(title: title)
        capture("01-explicit-Codex-example-real-compiler-saved")
        try openLibrary()
        let row = projectRow(title: title)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "A successful save must publish a project in the library")
        capture("01-example-library-after-real-save")

        app.terminate()
        app.launch()
        try openLibrary()
        let restored = projectRow(title: title)
        XCTAssertTrue(restored.waitForExistence(timeout: 15), "The same saved project must survive a cold process restart")
        try tapVisible(restored)
        XCTAssertTrue(previewElement().waitForExistence(timeout: 15), "Opening must load the saved model, not merely restore source text from a draft")
        assertNoOperationError()
        let titleField = sourceTitle()
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        XCTAssertEqual(titleField.value as? String, title)
        XCTAssertTrue(button(identifier: "codeEditor", label: "查看或编辑代码").exists)
        capture("01-cold-relaunch-same-project-opened")
    }

    func test02PastedSingleFenceImportsCompilesAndSavesThroughVisibleControls() throws {
        app.launch()
        try startNewWorkingSceneIfNeeded()
        let paste = button(identifier: "importCode", label: "粘贴代码")
        XCTAssertTrue(paste.waitForExistence(timeout: 10))
        try tapVisible(paste)
        XCTAssertTrue(app.navigationBars["粘贴 AI 场景代码"].waitForExistence(timeout: 5))
        let namedEditor = app.textViews["importSourceEditor"]
        let editor = namedEditor.waitForExistence(timeout: 2) ? namedEditor : app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        let source = """
        ```javascript
        const geometry = new THREE.BoxGeometry(0.4, 0.3, 0.2);
        const material = new THREE.MeshStandardMaterial({ color: 0x27ae60, roughness: 0.55, metalness: 0.1 });
        const mesh = new THREE.Mesh(geometry, material);
        mesh.name = "ui_import_control";
        mesh.position.set(0, 0.15, 0);
        scene.add(mesh);
        ```
        """
        editor.typeText(source)
        XCTAssertTrue((editor.value as? String)?.contains("```javascript") == true,
                      "The real TextEditor must receive the fenced input")
        capture("02-real-texteditor-fenced-source")
        let confirm = button(identifier: "confirmSceneImport", label: "导入")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5) && confirm.isEnabled)
        try tapVisible(confirm)
        try waitForImportedSource()
        let title = try makeUniqueTitle(marker: "UI粘贴")
        try compileAndSaveOnce(title: title)
        capture("02-pasted-source-real-compiler-saved")
        try openLibrary()
        XCTAssertTrue(projectRow(title: title).waitForExistence(timeout: 10))
        assertNoOperationError()
        capture("02-pasted-source-library")
    }

    /// Focused system-share acceptance, independent of the source editor's
    /// scrolling geometry. The bundled file is expected input only: the App
    /// receives it exclusively from its explicit example button, and the
    /// extension receives the App's actual saved source via NSItemProvider.
    func test04ExplicitSavedExampleSharesThroughSystemAndCompilesReceivedSource() throws {
        guard let fixtureURL = Bundle(for: SceneStudioUITests.self).url(forResource: "RobotScene", withExtension: "js") else {
            XCTFail("Copy the same production RobotScene.js into the UI-test resource bundle")
            throw UIAcceptanceError.missingControl
        }
        let expectedBytes = try Data(contentsOf: fixtureURL)
        guard let expectedSource = String(data: expectedBytes, encoding: .utf8), !expectedSource.isEmpty else {
            XCTFail("The expected scene resource must contain real UTF8 source")
            throw UIAcceptanceError.missingControl
        }
        XCTAssertEqual(Data(expectedSource.utf8), expectedBytes)
        XCTAssertLessThanOrEqual(expectedSource.count, 12_000, "This test requires the extension's full preview, not a truncated prefix")

        app.launch()
        try startNewWorkingSceneIfNeeded()
        try tapVisible(button(identifier: "importExample", label: "看看示例场景"))
        try waitForImportedSource()
        let originalTitle = try makeUniqueTitle(marker: "UI分享源")
        try compileAndSaveOnce(title: originalTitle)
        capture("04-explicit-example-really-compiled-and-saved")
        let pendingBefore = pendingSourceButtons().count
        let share = app.buttons["场景代码"]
        XCTAssertTrue(share.waitForExistence(timeout: 10))
        try tapVisible(share)
        capture("04-actual-source-system-share-sheet")

        var activity = systemShareControl(label: "存入维珀")
        if activity == nil,
           let more = systemShareControl(label: "更多") ?? systemShareControl(label: "More") {
            more.tap()
            activity = systemShareControl(label: "存入维珀")
        }
        guard let activity else {
            capture("04-system-share-activity-missing")
            XCTFail("The real system share activity must be available; no Inbox fixture replaces it")
            throw UIAcceptanceError.missingControl
        }
        activity.tap()

        var extensionRoot: XCUIApplication?
        let receiveDeadline = Date().addingTimeInterval(15)
        while extensionRoot == nil, Date() < receiveDeadline {
            extensionRoot = shareUIRoots().first { root in
                root.textViews.matching(NSPredicate(format: "value == %@", expectedSource)).firstMatch.exists
            }
            if extensionRoot == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        guard let extensionRoot else {
            capture("04-extension-full-source-mismatch-or-not-received")
            XCTFail("The actual extension preview must equal the complete bundled expected source")
            throw UIAcceptanceError.timeout
        }
        capture("04-extension-received-complete-source-awaits-confirmation")
        let saveInExtension = extensionRoot.buttons["存入维珀"]
        XCTAssertTrue(saveInExtension.waitForExistence(timeout: 5) && saveInExtension.isEnabled)
        saveInExtension.tap()
        let hostSavedAlert = app.alerts["已存入维珀"]
        let savedAlert = hostSavedAlert.waitForExistence(timeout: 15) ? hostSavedAlert
            : XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["已存入维珀"]
        XCTAssertTrue(savedAlert.waitForExistence(timeout: 5), "The extension's real atomic commit must succeed")
        capture("04-extension-commit-confirmed")
        let done = savedAlert.buttons["完成"]
        XCTAssertTrue(done.exists && done.isEnabled)
        done.tap()

        app.activate()  // A relaunch must not conceal a broken foreground refresh.
        let create = app.tabBars.buttons["创作"]
        if create.exists, create.isHittable { create.tap() }
        scrollCreatorToTop()
        let pendingDeadline = Date().addingTimeInterval(15)
        while pendingSourceButtons().count <= pendingBefore, Date() < pendingDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard pendingSourceButtons().count > pendingBefore else {
            capture("04-main-app-new-pending-share-not-visible")
            XCTFail("The just-saved system share must appear as a new pending entry without relaunch or injected data")
            throw UIAcceptanceError.timeout
        }
        XCTAssertTrue(app.staticTexts["收到分享"].exists)
        capture("04-main-app-received-new-system-share")

        // New is a visible working-draft action; no saved project or earlier
        // pending item is deleted. The newly committed share sorts first.
        let fresh = app.buttons["新建"]
        XCTAssertTrue(fresh.exists && fresh.isEnabled)
        fresh.tap()
        scrollCreatorToTop()
        let incoming = pendingSourceButtons().firstMatch
        XCTAssertTrue(incoming.waitForExistence(timeout: 5))
        try tapVisible(incoming)
        try waitForImportedSource()
        let expectedDisplayCount = ByteCountFormatter.string(fromByteCount: Int64(expectedBytes.count), countStyle: .file)
        XCTAssertTrue(app.staticTexts["已导入 \(expectedDisplayCount) 场景代码"].waitForExistence(timeout: 10),
                      "The imported source must report the same displayed byte count; exact file SHA is checked separately by host readback")
        let receivedTitle = try makeUniqueTitle(marker: "UI分享回收")
        try compileAndSaveOnce(title: receivedTitle)
        capture("04-received-system-share-really-recompiled-and-saved")
        try openLibrary()
        XCTAssertTrue(projectRow(title: originalTitle).waitForExistence(timeout: 10), "The original saved program must remain")
        XCTAssertTrue(projectRow(title: receivedTitle).waitForExistence(timeout: 10), "The reimported source must produce a second saved program")
        assertNoOperationError()
        capture("04-original-and-reimported-projects-in-library")

        let readback = XCTAttachment(string: "originalProjectTitle=\(originalTitle)\nreceivedProjectTitle=\(receivedTitle)\nexpectedResource=RobotScene.js\nexpectedSourceByteCount=\(expectedBytes.count)\nexactSourceAndInboxSHARequiresIndependentHostReadback=true")
        readback.name = "04-actual-project-titles-for-readonly-source-and-inbox-SHA-verification"
        readback.lifetime = .keepAlways
        add(readback)
    }

    private func pendingSourceButtons() -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "label == %@", "source.js"))
    }

    private func scrollCreatorToTop() {
        for _ in 0..<5 {
            let paste = button(identifier: "importCode", label: "粘贴代码")
            if paste.exists && paste.isHittable { return }
            app.swipeDown()
        }
    }

    private func shareUIRoots() -> [XCUIApplication] {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let extensionApp = XCUIApplication(bundleIdentifier: "com.kaisun.voxamber.scene-import")
        return [app, springboard] + (extensionApp.state == .notRunning ? [] : [extensionApp])
    }

    private func systemShareControl(label: String) -> XCUIElement? {
        // iOS may show the containing App's display name in its activity list,
        // while the actual extension's explicit save button is 存入维珀.
        let labels = label == "存入维珀" ? ["存入维珀", "维珀", "Voxamber"] : [label]
        let deadline = Date().addingTimeInterval(5)
        repeat {
            for root in shareUIRoots() {
                let button = root.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
                if button.exists && button.isHittable { return button }
                let cell = root.cells.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
                if cell.exists && cell.isHittable { return cell }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline
        return nil
    }

    private func startNewWorkingSceneIfNeeded() throws {
        let create = app.tabBars.buttons["创作"]
        if create.exists, create.isHittable { create.tap() }
        // New clears only the working draft through the actual UI. No projects,
        // history, container or persistent store are deleted by these tests.
        let fresh = app.buttons["新建"]
        if fresh.waitForExistence(timeout: 3), fresh.isEnabled { fresh.tap() }
        else if !button(identifier: "importExample", label: "看看示例场景").exists {
            XCTFail("Cannot obtain a new working scene through visible controls")
            throw UIAcceptanceError.missingControl
        }
        assertNoOperationError()
    }

    private func waitForImportedSource() throws {
        let imported = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "已导入 ")).firstMatch
        XCTAssertTrue(imported.waitForExistence(timeout: 15), "Import must complete before generation")
        XCTAssertTrue(sourceTitle().waitForExistence(timeout: 5))
        assertNoOperationError()
        let generate = button(identifier: "generateScene", label: "生成模型并保存")
        XCTAssertTrue(generate.waitForExistence(timeout: 5) && generate.isEnabled)
    }

    private func makeUniqueTitle(marker: String) throws -> String {
        let field = sourceTitle()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        try tapVisible(field)
        let suffix = " · " + marker + "-" + UUID().uuidString.prefix(8)
        field.typeText(suffix)
        guard let actual = field.value as? String, actual.contains(marker) else {
            XCTFail("The actual title field did not accept the unique marker")
            throw UIAcceptanceError.titleInput
        }
        // UITextField's return ends this single-line edit; it does not paste
        // an extra line into the scene source TextEditor.
        field.typeText("\n")
        return actual.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func compileAndSaveOnce(title: String) throws {
        let generate = button(identifier: "generateScene", label: "生成模型并保存")
        XCTAssertTrue(generate.waitForExistence(timeout: 5) && generate.isEnabled)
        try tapVisible(generate)
        // stage text is rendered only while busy. The success notice and
        // selected title are real persistent UI published after Store commit.
        let saved = app.staticTexts["可预览、分享模型，或把场景代码带回你的 AI 继续修改。"]
        let limit = Date().addingTimeInterval(60)
        while !saved.exists, !app.alerts.firstMatch.exists, Date() < limit {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if !saved.exists && !app.alerts.firstMatch.exists { capture("generation-timeout"); XCTFail("Real generation/save did not reach a terminal UI state"); throw UIAcceptanceError.timeout }
        assertNoOperationError()
        XCTAssertTrue(saved.exists, "The actual compile-and-publish path must report saved")
        XCTAssertTrue(app.staticTexts.matching(identifier: title).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["无法打开预览"].exists, "A native preview error must remain a failure")
        // Pixel/material acceptance is deliberately separate. Screenshots are
        // retained for the human review, never auto-passed based on color.
    }

    private func openLibrary() throws {
        let tab = app.tabBars.buttons["作品"]
        if tab.exists, tab.isHittable { tab.tap(); return }
        // Duo's wide NavigationSplitView shows the same real library alongside
        // the creator; its container is not an actionable tab button.
        let containers = [app.tables["library"], app.collectionViews["library"], app.otherElements["library"]]
        if containers.contains(where: { $0.exists }) { return }
        let label = app.buttons["作品"]
        if label.exists, label.isHittable { label.tap(); return }
        capture("missing-library-navigation")
        XCTFail("No library tab or visible wide-layout library was found")
        throw UIAcceptanceError.missingControl
    }

    private func projectRow(title: String) -> XCUIElement {
        let combined = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        if combined.exists { return combined }
        return app.buttons.containing(.staticText, identifier: title).firstMatch
    }

    private func sourceTitle() -> XCUIElement {
        let named = app.textFields["sourceTitle"]
        return named.exists ? named : app.textFields["作品名称"]
    }

    private func previewElement() -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@",
            "三维模型预览", "3D model preview")).firstMatch
    }

    private func button(identifier: String, label: String) -> XCUIElement {
        let named = app.buttons[identifier]
        return named.exists ? named : app.buttons[label]
    }

    private func tapVisible(_ element: XCUIElement) throws {
        let deadline = Date().addingTimeInterval(15)
        var scrollCount = 0
        repeat {
            if !element.exists || !element.isEnabled {
                // Wait on the actual disabled/busy state; do not tap or scroll
                // while an open/import operation still owns the controls.
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                continue
            }
            if element.isHittable && safelyAbovePersistentBars(element) { element.tap(); return }
            guard scrollCount < 8 else { break }
            let navigation = app.navigationBars.firstMatch
            let downward = navigation.exists && element.frame.minY < navigation.frame.maxY + 4
            if app.scrollViews.firstMatch.exists && app.scrollViews.firstMatch.isHittable {
                let scroll = app.scrollViews.firstMatch
                // The center contains RealityView, which correctly consumes
                // drags for orbiting. Scroll the real page at its outer margin.
                let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: downward ? 0.4 : 0.65))
                let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: downward ? 0.65 : 0.4))
                from.press(forDuration: 0.05, thenDragTo: to)
            } else if downward { app.swipeDown() }
            else { app.swipeUp() }
            scrollCount += 1
        } while Date() < deadline
        capture("control-not-hittable")
        XCTFail("The intended control did not become enabled, hittable, and visibly clear of persistent bars")
        throw UIAcceptanceError.missingControl
    }

    private func safelyAbovePersistentBars(_ element: XCUIElement) -> Bool {
        // The observed overlap belongs to the creator's code control. A
        // generation button retained in another tab's accessibility tree must
        // not impose its geometry on library rows or modal navigation buttons.
        guard ["codeEditor", "sourceTitle"].contains(element.identifier) || element.label == "场景代码" else { return true }
        let frame = element.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        let navigation = app.navigationBars.firstMatch
        if navigation.exists && frame.minY < navigation.frame.maxY + 4 { return false }
        let tabs = app.tabBars.firstMatch
        var bottom = tabs.exists ? tabs.frame.minY : app.frame.maxY
        let generate = app.buttons["generateScene"]
        if element.identifier != "generateScene", generate.exists, generate.isHittable {
            // In the recorded failure, AX called codeEditor hittable at y718.5
            // while the persistent generation backdrop obscured it. Scroll its
            // full frame above the bar, including its surrounding hit area.
            bottom = min(bottom, generate.frame.minY - 24)
        }
        return frame.maxY <= bottom
    }

    private func assertNoOperationError(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.alerts.firstMatch.exists, "An actual App error alert is present", file: file, line: line)
        XCTAssertFalse(app.staticTexts["本次操作未完成"].exists, file: file, line: line)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private enum UIAcceptanceError: Error { case timeout, missingControl, titleInput }
