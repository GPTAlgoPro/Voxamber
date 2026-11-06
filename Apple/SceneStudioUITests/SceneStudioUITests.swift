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
        for _ in 0..<5 {
            if element.exists, element.isHittable { element.tap(); return }
            app.swipeUp()
        }
        capture("control-not-hittable")
        XCTFail("The intended visible UI control could not be reached")
        throw UIAcceptanceError.missingControl
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
