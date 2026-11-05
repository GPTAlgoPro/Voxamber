#if os(iOS)
import SwiftUI
import CreationCore

public struct ScaleControlDemo: View {
    @Environment(\.locale) private var locale
    @State private var tiny: Float = 0.001
    @State private var length: Float = 3.5
    @State private var large: Float = 100
    @State private var position: Float = 1000
    @State private var invalid: Set<String> = []
    @State private var validated = false

    public init() {}
    private var english: Bool { locale.language.languageCode?.identifier != "zh" }
    private func text(_ chinese: String, _ english: String) -> String { self.english ? english : chinese }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(text("从毫米到大型创作", "From details to larger ideas"))
                        .font(.title2.weight(.semibold))
                    Text(text("直接输入精确数值，或用滑杆微调。尺寸与位置始终按米保存。", "Enter precise values, or fine-tune nearby. Dimensions and positions use meters."))
                        .font(.subheadline).foregroundStyle(.secondary)
                    VStack(spacing: 20) {
                        control(text("尺寸 X", "Dimension X"), value: $tiny, range: SceneLimits.dimensionRange, unit: .millimetres)
                        control(text("尺寸 Y", "Dimension Y"), value: $length, range: SceneLimits.dimensionRange)
                        control(text("尺寸 Z", "Dimension Z"), value: $large, range: SceneLimits.dimensionRange)
                    }.padding(18).background(.regularMaterial, in: .rect(cornerRadius: 22))
                    VStack(spacing: 16) {
                        control(text("位置 X", "Position X"), value: $position, range: SceneLimits.positionRange, span: 0.1)
                    }.padding(18).background(.regularMaterial, in: .rect(cornerRadius: 22))
                    if validated {
                        Label(text("数值有效，已保留你的精确修改。", "Values checked. Your precise edits are kept."), systemImage: "checkmark.circle")
                            .font(.footnote).foregroundStyle(.mint)
                    }
                }.padding(20)
            }
            .navigationTitle(text("尺寸与位置", "Dimensions & position"))
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaBar(edge: .bottom) {
                Button { validated = true } label: {
                    Text(text("应用修改", "Apply changes")).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 10)
                }.buttonStyle(.glassProminent).disabled(!invalid.isEmpty)
                    .padding(.horizontal, 20).padding(.vertical, 10)
            }
            .background {
                LinearGradient(colors: [Color(red: 0.035, green: 0.10, blue: 0.17),
                    Color(red: 0.12, green: 0.10, blue: 0.28)], startPoint: .topLeading,
                    endPoint: .bottomTrailing).ignoresSafeArea()
            }
        }.tint(.mint).preferredColorScheme(.dark)
    }

    private func control(_ label: String, value: Binding<Float>, range: ClosedRange<Float>,
                         span: Double? = nil, unit: SIEditingUnit = .metres) -> some View {
        NumericAxisControl(label, value: value,
            configuration: .init(range: range, preferredSliderSpan: span, initialUnit: unit),
            onValidityChanged: { valid in
                if valid { invalid.remove(label) } else { invalid.insert(label) }
            })
    }
}
#endif
