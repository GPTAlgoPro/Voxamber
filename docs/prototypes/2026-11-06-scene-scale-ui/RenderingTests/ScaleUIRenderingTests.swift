import XCTest
import SwiftUI
import SceneScaleUIPrototype

@MainActor
final class ScaleUIRenderingTests: XCTestCase {
    func testRender390By844WithStandardAndAccessibilityText() async throws {
        let destination = URL.documentsDirectory.appending(path: "ScaleUIEvidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for (name, size) in [("standard", DynamicTypeSize.large), ("accessibility", .accessibility3)] {
            let content = ScaleControlDemo().environment(\.locale, Locale(identifier: "en_US"))
                .dynamicTypeSize(size).frame(width: 390, height: 844)
            let controller = UIHostingController(rootView: content)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844), format: format).image { _ in
                controller.view.drawHierarchy(in: CGRect(x: 0, y: 0, width: 390, height: 844), afterScreenUpdates: true)
            }
            XCTAssertEqual(image.cgImage?.width, 390)
            XCTAssertEqual(image.cgImage?.height, 844)
            try XCTUnwrap(image.pngData()).write(to: destination.appending(path: name + ".png"), options: .atomic)
            let scroll = try XCTUnwrap(scrollViews(in: controller.view).first)
            let bottom = max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            try await Task.sleep(for: .milliseconds(120))
            let fields = textFields(in: controller.view)
            XCTAssertTrue(fields.contains { $0.text == "1000" }, "Large position value must remain in the real editor")
            for field in fields {
                let bounds = field.convert(field.bounds, to: controller.view)
                XCTAssertGreaterThanOrEqual(bounds.minX, -1)
                XCTAssertLessThanOrEqual(bounds.maxX, controller.view.bounds.width + 1,
                                         "Numeric fields must fit horizontally at each Dynamic Type size")
            }
            let bottomImage = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 844), format: format).image { _ in
                controller.view.drawHierarchy(in: CGRect(x: 0, y: 0, width: 390, height: 844), afterScreenUpdates: true)
            }
            try XCTUnwrap(bottomImage.pngData()).write(to: destination.appending(path: name + "-position.png"), options: .atomic)
            window.isHidden = true
        }
    }

    func testAppearanceDoesNotWriteOrClampAnExistingValue() async throws {
        for initial: Float in [0.001, 3.5, 1000, 5000] {
            let box = RenderValue(initial)
            let value = Binding<Float>(get: { box.value }, set: { box.writes += 1; box.value = $0 })
            let content = NumericAxisControl("Position X", value: value,
                configuration: .init(range: -1000...1000, preferredSliderSpan: 0.1))
                .environment(\.locale, Locale(identifier: "en_US"))
                .padding(20).frame(width: 390, height: 300)
            let controller = UIHostingController(rootView: content)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(120))
            controller.view.layoutIfNeeded()
            let field = try XCTUnwrap(textFields(in: controller.view).first)
            XCTAssertEqual(field.text, NumericAxisInput.text(for: initial, unit: .metres),
                           "The actual TextField must have appeared and received its draft")
            XCTAssertEqual(field.keyboardType, .numbersAndPunctuation)
            XCTAssertEqual(box.value.bitPattern, initial.bitPattern)
            XCTAssertEqual(box.writes, 0, "Appearance may format a draft, but must not mutate model data")
            window.isHidden = true
        }
    }

    func testInvalidTypedDraftKeepsModelAndValidMillimetresCommitOnBlur() async throws {
        let box = RenderValue(3.5)
        let binding = Binding<Float>(get: { box.value }, set: { box.writes += 1; box.value = $0 })
        let content = NumericAxisControl("Dimension X", value: binding,
            configuration: .init(range: 0.001...100), onValidityChanged: { box.valid = $0 })
            .environment(\.locale, Locale(identifier: "en_US"))
            .padding(20).frame(width: 390, height: 400)
        let controller = UIHostingController(rootView: content)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(150))
        let field = try XCTUnwrap(textFields(in: controller.view).first)
        XCTAssertTrue(field.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(80))
        field.text = "101"
        field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertFalse(box.valid)
        XCTAssertEqual(box.value, 3.5)
        XCTAssertEqual(box.writes, 0)
        field.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(box.value, 3.5, "An invalid blur must keep the last valid model value")
        XCTAssertEqual(box.writes, 0)
        XCTAssertTrue(field.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(80))
        field.text = "2 mm"
        field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(box.valid)
        field.resignFirstResponder()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(box.value, Float(0.002))
        XCTAssertEqual(box.writes, 1, "Only the valid explicit edit is written back")
    }

    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}

@MainActor
private final class RenderValue {
    var value: Float
    var writes = 0
    var valid = true
    init(_ value: Float) { self.value = value }
}
