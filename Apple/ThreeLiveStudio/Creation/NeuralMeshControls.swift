import SwiftUI

struct NeuralMeshControls: View {
    @Binding var recipe: NeuralEditRecipe
    let busy: Bool
    let onSave: () -> Void
    let onReset: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    // Only unfinished text is owned here. Valid edits immediately update the
    // immutable recipe, so Save cannot accidentally use a stale valid draft.
    @State private var drafts: [NeuralMeshField: String] = [:]
    @State private var editError: String?
    @FocusState private var focusedField: NeuralMeshField?

    private var recipeIsValid: Bool {
        do { try recipe.validate(); return true } catch { return false }
    }
    private var invalidDraft: Bool {
        drafts.contains { field, text in
            (recipe.wholeMaterial != nil || !field.isMaterial) && field.parse(text, locale: locale) == nil
        }
    }
    private var canSave: Bool { !busy && recipeIsValid && !invalidDraft && editError == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label(StudioCopy.text("整体网格编辑", "Whole mesh"), systemImage: "slider.horizontal.3")
                    .font(.headline)
                Text(StudioCopy.text("位置使用模型单位，大小使用比例。", "Position uses model units; size uses ratios."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                transformCard(.translation)
                transformCard(.rotation)
                transformCard(.scale)
                materialCard
            }
            if let editError {
                Label(editError, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            GlassEffectContainer(spacing: 12) {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Button(StudioCopy.text("复位编辑", "Reset edits"), systemImage: "arrow.counterclockwise") {
                        guard !busy else { return }
                        drafts.removeAll(); editError = nil; focusedField = nil
                        onReset()
                    }.buttonStyle(.glass).disabled(busy)
                        .accessibilityIdentifier("neural-edit-reset")
                    Button(StudioCopy.text("保存编辑", "Save edits"), systemImage: "checkmark") {
                        guard canSave else { return }
                        focusedField = nil
                        onSave()
                    }.buttonStyle(.glassProminent).disabled(!canSave)
                        .accessibilityIdentifier("neural-edit-save")
                }
            }
        }
        .accessibilityIdentifier("neural-mesh-controls")
        .onChange(of: recipe) { old, new in
            for field in Array(drafts.keys) {
                if field.isMaterial && new.wholeMaterial == nil { drafts.removeValue(forKey: field) }
                else if field.value(in: old) != field.value(in: new),
                        field.parse(drafts[field] ?? "", locale: locale) != field.value(in: new) {
                    drafts[field] = String(field.value(in: new))
                }
            }
        }
        .onChange(of: busy) { _, active in if active { focusedField = nil } }
    }

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize ? [GridItem(.flexible(minimum: 0))]
            : [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)]
    }

    private func transformCard(_ group: NeuralMeshGroup) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(group.title).font(.headline)
            ForEach(NeuralMeshAxis.allCases, id: \.self) { axis in
                scalarRow(group.field(axis))
            }
        }.frame(maxWidth: .infinity, alignment: .leading).studioCard().disabled(busy)
    }

    private var materialCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(StudioCopy.text("整体材质", "Whole material"), isOn: Binding(
                get: { recipe.wholeMaterial != nil },
                set: { enabled in
                    guard !busy else { return }
                    do {
                        let material = enabled ? try NeuralWholeMaterial(rgba: [0.21404114048223255, 0.21404114048223255, 0.21404114048223255, 1], metallic: 0, roughness: 0.5) : nil
                        let proposed = try NeuralEditRecipe(translationXYZ: recipe.translationXYZ,
                            rotationXYZdegrees: recipe.rotationXYZdegrees, positiveScaleXYZ: recipe.positiveScaleXYZ,
                            wholeMaterial: material)
                        if proposed != recipe { recipe = proposed }
                        drafts = drafts.filter { !$0.key.isMaterial }; editError = nil
                    } catch { editError = invalidRecipeMessage }
                }))
                .font(.headline).accessibilityIdentifier("neural-material-enabled")
            if let material = recipe.wholeMaterial {
                NeuralMeshColorPicker(material: Binding(get: { recipe.wholeMaterial ?? material }, set: { new in
                    guard !busy, recipe.wholeMaterial != nil else { return }
                    replaceMaterial(new)
                }), busy: busy, onFailure: { editError = $0 })
                scalarRow(.opacity)
                scalarRow(.metallic)
                scalarRow(.roughness)
            } else {
                Text(StudioCopy.text("保留原始材质", "Keep original material"))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).studioCard().disabled(busy)
    }

    private func scalarRow(_ field: NeuralMeshField) -> some View {
        let text = drafts[field] ?? String(field.value(in: recipe))
        let invalid = field.parse(text, locale: locale) == nil
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(field.label).font(.subheadline).fixedSize()
                TextField(field.label, text: textBinding(field))
                    .textFieldStyle(.roundedBorder).font(.body.monospacedDigit())
                    .keyboardType(.numbersAndPunctuation).autocorrectionDisabled()
                    .textInputAutocapitalization(.never).multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: field)
                    .accessibilityLabel(field.accessibilityLabel)
                    .accessibilityIdentifier("neural-" + field.id)
                if !field.unit.isEmpty { Text(field.unit).font(.caption).foregroundStyle(.secondary) }
            }
            if invalid {
                Text(field.validationMessage).font(.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("neural-error-" + field.id)
            }
            // SwiftUI Slider never receives an out-of-domain current value:
            // it cannot clamp a large existing recipe merely by appearing.
            if field.sliderRange.contains(field.value(in: recipe)), !invalid {
                Slider(value: Binding(get: { field.value(in: recipe) }, set: { value in
                    guard !busy else { return }
                    update(field, value: value)
                    drafts[field] = String(value)
                }), in: field.sliderRange)
                    .accessibilityLabel(field.accessibilityLabel)
                    .accessibilityIdentifier("neural-slider-" + field.id)
            }
        }
    }

    private func textBinding(_ field: NeuralMeshField) -> Binding<String> {
        Binding(get: { drafts[field] ?? String(field.value(in: recipe)) }, set: { text in
            guard !busy else { return }
            drafts[field] = text
            guard let value = field.parse(text, locale: locale) else { return }
            update(field, value: value)
        })
    }
    private func update(_ field: NeuralMeshField, value: Double) {
        guard !busy else { return }
        do {
            let proposed = try field.applying(value, to: recipe)
            if proposed != recipe { recipe = proposed }
            editError = nil
        }
        catch { editError = invalidRecipeMessage }
    }
    private func replaceMaterial(_ material: NeuralWholeMaterial) {
        do {
            let proposed = try NeuralEditRecipe(translationXYZ: recipe.translationXYZ,
                rotationXYZdegrees: recipe.rotationXYZdegrees, positiveScaleXYZ: recipe.positiveScaleXYZ,
                wholeMaterial: material)
            if proposed != recipe { recipe = proposed }
            editError = nil
        } catch { editError = invalidRecipeMessage }
    }
    private var invalidRecipeMessage: String {
        StudioCopy.text("当前数值无法保存，请检查或复位编辑。", "Check the values or reset edits before saving.")
    }
}

private struct NeuralMeshColorPicker: View {
    @Binding var material: NeuralWholeMaterial
    let busy: Bool
    let onFailure: (String) -> Void
    @Environment(\.self) private var environment

    var body: some View {
        ColorPicker(StudioCopy.text("颜色与透明度", "Color and opacity"), selection: Binding(
            get: { NeuralMeshColor.color(material.rgba) },
            set: { color in
                guard !busy else { return }
                do { material = try NeuralMeshColor.material(color, in: environment, keeping: material) }
                catch { onFailure(StudioCopy.text("请选择可保存的标准色域颜色。", "Choose a color within the supported range.")) }
            }), supportsOpacity: true)
            .accessibilityIdentifier("neural-material-color")
    }
}

enum NeuralMeshColor {
    static func color(_ rgba: [Double]) -> Color {
        Color(.sRGBLinear, red: rgba[0], green: rgba[1], blue: rgba[2], opacity: rgba[3])
    }
    static func material(_ color: Color, in environment: EnvironmentValues,
                         keeping original: NeuralWholeMaterial) throws -> NeuralWholeMaterial {
        // SwiftUI resolves a ColorPicker sRGB color into linear sRGB primaries
        // (Rec.709). Alpha is coverage and receives no gamma transform.
        let resolved = color.resolve(in: environment)
        return try NeuralWholeMaterial(rgba: [Double(resolved.linearRed), Double(resolved.linearGreen),
                                              Double(resolved.linearBlue), Double(resolved.opacity)],
                                       metallic: original.metallic, roughness: original.roughness)
    }
}

enum NeuralMeshAxis: Int, CaseIterable { case x, y, z
    var label: String { switch self { case .x: "X"; case .y: "Y"; case .z: "Z" } }
}
private enum NeuralMeshGroup { case translation, rotation, scale
    var title: String {
        switch self {
        case .translation: StudioCopy.text("整体位移", "Position")
        case .rotation: StudioCopy.text("整体旋转", "Rotation")
        case .scale: StudioCopy.text("整体比例", "Scale")
        }
    }
    func field(_ axis: NeuralMeshAxis) -> NeuralMeshField {
        switch self { case .translation: .translation(axis); case .rotation: .rotation(axis); case .scale: .scale(axis) }
    }
}

enum NeuralMeshField: Hashable {
    case translation(NeuralMeshAxis), rotation(NeuralMeshAxis), scale(NeuralMeshAxis), opacity, metallic, roughness
    var id: String {
        switch self {
        case .translation(let axis): "translation-" + axis.label.lowercased()
        case .rotation(let axis): "rotation-" + axis.label.lowercased()
        case .scale(let axis): "scale-" + axis.label.lowercased()
        case .opacity: "opacity"; case .metallic: "metallic"; case .roughness: "roughness"
        }
    }
    var label: String {
        switch self {
        case .translation(let axis), .rotation(let axis), .scale(let axis): axis.label
        case .opacity: StudioCopy.text("不透明度", "Opacity")
        case .metallic: StudioCopy.text("金属度", "Metallic")
        case .roughness: StudioCopy.text("粗糙度", "Roughness")
        }
    }
    var accessibilityLabel: String {
        switch self {
        case .translation: StudioCopy.text("位移 ", "Position ") + label
        case .rotation: StudioCopy.text("旋转 ", "Rotation ") + label
        case .scale: StudioCopy.text("比例 ", "Scale ") + label
        default: label
        }
    }
    var unit: String {
        switch self {
        case .translation: StudioCopy.text("模型单位", "units")
        case .rotation: "°"
        case .scale: "×"
        default: ""
        }
    }
    var isMaterial: Bool { switch self { case .opacity, .metallic, .roughness: true; default: false } }
    var sliderRange: ClosedRange<Double> {
        switch self { case .translation: -2...2; case .rotation: -180...180; case .scale: 0.1...3; default: 0...1 }
    }
    var validationMessage: String {
        switch self {
        case .scale: StudioCopy.text("比例必须是大于零的有限数值。", "Use a finite ratio greater than zero.")
        case .opacity, .metallic, .roughness: StudioCopy.text("请输入 0 到 1 之间的数值。", "Use a value from 0 to 1.")
        default: StudioCopy.text("请输入有限数值。", "Enter a finite number.")
        }
    }
    func parse(_ text: String, locale: Locale) -> Double? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "−", with: "-")
        if locale.decimalSeparator == ",", !text.contains(".") { text = text.replacingOccurrences(of: ",", with: ".") }
        guard let value = Double(text), value.isFinite else { return nil }
        switch self {
        case .scale: guard value > 0 else { return nil }
        case .opacity, .metallic, .roughness: guard (0...1).contains(value) else { return nil }
        default: break
        }
        return value
    }
    func value(in recipe: NeuralEditRecipe) -> Double {
        switch self {
        case .translation(let axis): recipe.translationXYZ.indices.contains(axis.rawValue) ? recipe.translationXYZ[axis.rawValue] : .nan
        case .rotation(let axis): recipe.rotationXYZdegrees.indices.contains(axis.rawValue) ? recipe.rotationXYZdegrees[axis.rawValue] : .nan
        case .scale(let axis): recipe.positiveScaleXYZ.indices.contains(axis.rawValue) ? recipe.positiveScaleXYZ[axis.rawValue] : .nan
        case .opacity: recipe.wholeMaterial?.rgba[3] ?? .nan
        case .metallic: recipe.wholeMaterial?.metallic ?? .nan
        case .roughness: recipe.wholeMaterial?.roughness ?? .nan
        }
    }
    func applying(_ value: Double, to recipe: NeuralEditRecipe) throws -> NeuralEditRecipe {
        try recipe.validate()
        var translation = recipe.translationXYZ, rotation = recipe.rotationXYZdegrees, scale = recipe.positiveScaleXYZ
        var material = recipe.wholeMaterial
        switch self {
        case .translation(let axis): translation[axis.rawValue] = value
        case .rotation(let axis): rotation[axis.rawValue] = value
        case .scale(let axis): scale[axis.rawValue] = value
        case .opacity, .metallic, .roughness:
            guard let current = material else { throw ProjectStorageError.invalidMetadata }
            var rgba = current.rgba
            if self == .opacity { rgba[3] = value }
            material = try NeuralWholeMaterial(rgba: rgba, metallic: self == .metallic ? value : current.metallic,
                                               roughness: self == .roughness ? value : current.roughness)
        }
        return try NeuralEditRecipe(translationXYZ: translation, rotationXYZdegrees: rotation,
                                    positiveScaleXYZ: scale, wholeMaterial: material)
    }
}
