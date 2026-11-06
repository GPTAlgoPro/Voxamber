import XCTest
import SwiftUI
import UIKit
import Observation
@testable import ThreeLiveStudio

@MainActor
final class NeuralMeshControlsTests: XCTestCase {
    func testAppearanceAndReflowKeepExistingExactRecipeWithoutWrites() async throws {
        let initial = try NeuralEditRecipe(translationXYZ: [12345.6789012345, -42, 0.0000000123456789],
            rotationXYZdegrees: [720, -450, 12.345678912345], positiveScaleXYZ: [0.000001, 4.25, 120],
            wholeMaterial: NeuralWholeMaterial(rgba: [0.123456789, 0.6, 0.02, 0.37], metallic: 0.123, roughness: 0.789))
        let state = NeuralControlsHarness(initial)
        for (size, type) in [(CGSize(width: 390, height: 844), DynamicTypeSize.large),
                             (CGSize(width: 944, height: 850), .large),
                             (CGSize(width: 390, height: 844), .accessibility3)] {
            let (host, window) = try mount(state, size: size, type: type)
            try await Task.sleep(for: .milliseconds(180))
            host.view.layoutIfNeeded()
            let fields = textFields(in: host.view)
            XCTAssertFalse(fields.isEmpty, "Native controls must actually be mounted")
            for field in fields {
                let bounds = field.convert(field.bounds, to: host.view)
                XCTAssertGreaterThanOrEqual(bounds.minX, -1)
                XCTAssertLessThanOrEqual(bounds.maxX, size.width + 1)
            }
            XCTAssertEqual(state.recipe, initial)
            XCTAssertEqual(state.writes, 0, "Showing a slider or color picker must not rewrite imported values")
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Neural-controls-\(Int(size.width))-\(type)"
            attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }

    func testActualTextFieldWritesFullPrecisionOutsideSliderRangeAndPreservesOtherFields() async throws {
        let original = try NeuralEditRecipe(translationXYZ: [0.125,0,0], rotationXYZdegrees: [12, 23, 34],
            positiveScaleXYZ: [1.1,1.2,1.3],
            wholeMaterial: NeuralWholeMaterial(rgba: [0.1,0.2,0.3,0.4], metallic: 0.6, roughness: 0.7))
        let state = NeuralControlsHarness(original)
        let (host, window) = try mount(state, size: CGSize(width: 944, height: 1300))
        defer { host.view.endEditing(true); window.isHidden = true }
        let field = try await findField("neural-translation-x", currentText: String(original.translationXYZ[0]), in: host)
        XCTAssertTrue(field.becomeFirstResponder())
        field.text = "-12345.6789012345"; field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.recipe.translationXYZ[0], -12345.6789012345)
        XCTAssertEqual(state.recipe.translationXYZ[1...], original.translationXYZ[1...])
        XCTAssertEqual(state.recipe.rotationXYZdegrees, original.rotationXYZdegrees)
        XCTAssertEqual(state.recipe.positiveScaleXYZ, original.positiveScaleXYZ)
        XCTAssertEqual(state.recipe.wholeMaterial, original.wholeMaterial)
        XCTAssertEqual(state.writes, 1)
        field.resignFirstResponder()
        let scale = try await findField("neural-scale-z", currentText: String(original.positiveScaleXYZ[2]), in: host)
        XCTAssertTrue(scale.becomeFirstResponder())
        scale.text = "1e-8"; scale.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.recipe.positiveScaleXYZ, [1.1,1.2,1e-8])
        XCTAssertEqual(state.recipe.translationXYZ[0], -12345.6789012345)
        XCTAssertEqual(state.recipe.wholeMaterial, original.wholeMaterial)
        XCTAssertEqual(state.writes, 2)
    }

    func testInvalidDraftDoesNotReplaceRecipeAndSurvivesWidthChange() async throws {
        let initial = try NeuralEditRecipe(translationXYZ: [0.11,0.22,0.33],
            rotationXYZdegrees: [11,22,33], positiveScaleXYZ: [1.234,2.345,3.456])
        let state = NeuralControlsHarness(initial)
        let (host, window) = try mount(state, size: CGSize(width: 944, height: 1300))
        defer { host.view.endEditing(true); window.isHidden = true }
        let field = try await findField("neural-scale-x", currentText: "1.234", in: host)
        XCTAssertTrue(field.becomeFirstResponder())
        field.text = "0"; field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.recipe, initial)
        XCTAssertEqual(state.writes, 0)
        window.frame.size.width = 390; host.view.frame.size.width = 390
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        let current = try await findField("neural-scale-x", currentText: "0", in: host)
        XCTAssertEqual(current.text, "0")
        XCTAssertEqual(state.recipe, initial)
        current.text = "2.75"; current.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.recipe.positiveScaleXYZ, [2.75,2.345,3.456])
        XCTAssertEqual(state.writes, 1)
    }

    func testBusyDisablesNativeFieldsAndRejectsEditingEvents() async throws {
        let initial = try NeuralEditRecipe(translationXYZ: [0.25,0,0])
        let state = NeuralControlsHarness(initial)
        let (host, window) = try mount(state, size: CGSize(width: 390, height: 844))
        defer { host.view.endEditing(true); window.isHidden = true }
        let field = try await findField("neural-translation-x", currentText: "0.25", in: host)
        state.busy = true
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(field.isEnabled)
        field.text = "99"; field.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.recipe, initial)
        XCTAssertEqual(state.writes, 0)
        XCTAssertEqual(state.saves, 0)
        XCTAssertEqual(state.resets, 0)
    }

    func testNativeColorResolutionConvertsSRGBToLinearAndPreservesCoverageAndMaterial() throws {
        let original = try NeuralWholeMaterial(rgba: [0.9,0.8,0.7,1], metallic: 0.62, roughness: 0.31)
        let updated = try NeuralMeshColor.material(Color(.sRGB, red: 0.5, green: 0.25, blue: 0.75, opacity: 0.4),
                                                  in: EnvironmentValues(), keeping: original)
        XCTAssertEqual(updated.rgba[0], 0.21404114048223255, accuracy: 0.000001)
        XCTAssertEqual(updated.rgba[1], 0.05087608817155679, accuracy: 0.000001)
        XCTAssertEqual(updated.rgba[2], 0.5225215539683921, accuracy: 0.000001)
        XCTAssertEqual(updated.rgba[3], 0.4, accuracy: 0.000001)
        XCTAssertEqual(updated.metallic, original.metallic)
        XCTAssertEqual(updated.roughness, original.roughness)
        let back = NeuralMeshColor.color(updated.rgba).resolve(in: EnvironmentValues())
        XCTAssertEqual(Double(back.linearRed), updated.rgba[0], accuracy: 0.000001)
        XCTAssertEqual(Double(back.opacity), 0.4, accuracy: 0.000001)
    }

    private func mount(_ state: NeuralControlsHarness, size: CGSize, type: DynamicTypeSize = .large)
        throws -> (UIHostingController<NeuralControlsHarnessView>, UIWindow) {
        let host = UIHostingController(rootView: NeuralControlsHarnessView(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size); window.rootViewController = host
        host.view.frame = window.bounds
        host.overrideUserInterfaceStyle = .dark
        host.rootView = NeuralControlsHarnessView(state: state, type: type)
        window.makeKeyAndVisible(); host.view.frame = CGRect(origin: .zero, size: size)
        return (host, window)
    }
    private func findField(_ id: String, currentText: String,
                           in host: UIHostingController<NeuralControlsHarnessView>) async throws -> UITextField {
        for fraction: CGFloat in [0, 0.35, 0.7, 1] {
            host.view.layoutIfNeeded()
            let identified = viewWithIdentifier(id, in: host.view).flatMap({ ($0 as? UITextField) ?? textFields(in: $0).first })
            // SwiftUI accessibility IDs describe the accessibility tree; the
            // native UITextField does not necessarily receive that UIView property.
            // Fixtures use unique values, then assert the actual bound recipe
            // field changes, avoiding dependence on visual subview ordering.
            let matches = textFields(in: host.view).filter { $0.text == currentText }
            if let field = identified ?? (matches.count == 1 ? matches[0] : nil) {
                if identified == nil {
                    let diagnostic = textFields(in: host.view).map {
                        ["nativeIdentifier":$0.accessibilityIdentifier ?? "<nil>",
                         "nativeLabel":$0.accessibilityLabel ?? "<nil>",
                         "placeholder":$0.placeholder ?? "<nil>", "fixtureValue":$0.text ?? "<nil>"]
                    }
                    let attachment = XCTAttachment(string: String(describing: diagnostic))
                    attachment.name = "Native-field-vs-SwiftUI-accessibility-\(id)"
                    attachment.lifetime = .keepAlways; add(attachment)
                }
                if let scroll = scrollViews(in: host.view).first {
                    scroll.scrollRectToVisible(field.convert(field.bounds, to: scroll), animated: false)
                }
                try await Task.sleep(for: .milliseconds(60))
                return field
            }
            if let scroll = scrollViews(in: host.view).first {
                scroll.setContentOffset(CGPoint(x: 0, y: max(0, scroll.contentSize.height - scroll.bounds.height) * fraction), animated: false)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Native field not mounted: \(id)")
        throw NeuralControlsTestError.fieldNotFound
    }
    private func viewWithIdentifier(_ id: String, in view: UIView) -> UIView? {
        if view.accessibilityIdentifier == id { return view }
        return view.subviews.lazy.compactMap { self.viewWithIdentifier(id, in: $0) }.first
    }
    private func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
}

private enum NeuralControlsTestError: Error { case fieldNotFound }

@MainActor @Observable
private final class NeuralControlsHarness {
    var recipe: NeuralEditRecipe
    var busy = false
    var writes = 0
    var saves = 0
    var resets = 0
    init(_ recipe: NeuralEditRecipe) { self.recipe = recipe }
}

@MainActor
private struct NeuralControlsHarnessView: View {
    @Bindable var state: NeuralControlsHarness
    var type: DynamicTypeSize = .large
    var body: some View {
        ScrollView {
            NeuralMeshControls(recipe: Binding(get: { state.recipe }, set: { state.writes += 1; state.recipe = $0 }),
                busy: state.busy, onSave: { state.saves += 1 }, onReset: { state.resets += 1 })
                .padding(12)
        }.background(StudioStyle.ink).dynamicTypeSize(type)
            .environment(\.locale, Locale(identifier: "en_US"))
    }
}
