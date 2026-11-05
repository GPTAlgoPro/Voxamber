import SwiftUI

public struct NumericAxisConfiguration: Sendable {
    public var range: ClosedRange<Float>
    public var preferredSliderSpan: Double?
    public var initialUnit: SIEditingUnit

    public init(range: ClosedRange<Float>, preferredSliderSpan: Double? = nil,
                initialUnit: SIEditingUnit = .metres) {
        self.range = range; self.preferredSliderSpan = preferredSliderSpan; self.initialUnit = initialUnit
    }
}

public struct NumericAxisControl: View {
    let label: String
    @Binding private var value: Float
    let configuration: NumericAxisConfiguration
    let onValidityChanged: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.locale) private var locale
    @FocusState private var focused: Bool
    // These states own only an uncommitted edit and the user's unit preference.
    // The authoritative model remains the injected binding.
    @State private var draft = ""
    @State private var unit: SIEditingUnit
    @State private var adjustment = NumericAxisAdjustment()
    @State private var hasAppeared = false

    public init(_ label: String, value: Binding<Float>, configuration: NumericAxisConfiguration,
                onValidityChanged: @escaping (Bool) -> Void = { _ in }) {
        self.label = label; _value = value; self.configuration = configuration
        self.onValidityChanged = onValidityChanged
        _unit = State(initialValue: configuration.initialUnit)
    }

    private var errorMessage: String? {
        do { _ = try NumericAxisInput.parse(draft, unit: unit, range: configuration.range, locale: locale); return nil }
        catch let error as NumericAxisInputError { return error.message(locale: locale) }
        catch { return error.localizedDescription }
    }
    private var english: Bool { locale.language.languageCode?.identifier != "zh" }
    private var changed: Bool { draft != NumericAxisInput.text(for: value, unit: unit) }
    private var domain: NumericAxisDomain? {
        adjustment.domain(value: value, allowed: configuration.range,
                          preferredSpan: configuration.preferredSliderSpan)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.weight(.medium))
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                field.frame(maxWidth: .infinity)
                HStack(spacing: 8) {
                    Menu {
                        ForEach(SIEditingUnit.allCases, id: \.self) { option in
                            Button(option.rawValue) { unit = option; refreshDraft() }
                        }
                    } label: {
                        Text(unit.rawValue).font(.body.monospaced()).frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(.glass).disabled(focused)
                        .accessibilityLabel(label + (english ? " unit" : " 单位"))
                    Button { if commit() { focused = false } } label: {
                        Image(systemName: "checkmark").frame(minWidth: 44, minHeight: 44)
                    }.buttonStyle(.glass).disabled(errorMessage != nil || !changed)
                        .accessibilityLabel((english ? "Apply " : "应用 ") + label)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("numeric-error-" + label)
            }
            if let domain, domain.range.contains(Double(value)) {
                Slider(value: sliderValue, in: domain.range, onEditingChanged: { active in
                    if active {
                        adjustment.begin(value: value, allowed: configuration.range,
                                         preferredSpan: configuration.preferredSliderSpan)
                    } else { adjustment.end(); refreshDraft() }
                }).disabled(focused || errorMessage != nil)
                    .accessibilityLabel(label + (english ? " fine adjustment" : " 微调"))
                HStack {
                    Text(domain.range.lowerBound, format: .number.precision(.significantDigits(1...5)))
                    Spacer()
                    Text(domain.range.upperBound, format: .number.precision(.significantDigits(1...5)))
                    Text("m")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if !hasAppeared { hasAppeared = true; refreshDraft() }
            else { onValidityChanged(errorMessage == nil) }
        }
        .onChange(of: value) { _, _ in if !focused { refreshDraft() } }
        .onChange(of: draft) { _, _ in onValidityChanged(errorMessage == nil) }
        .onChange(of: focused) { _, active in if !active { _ = commit() } }
    }

    private var field: some View {
        TextField(label, text: $draft)
            .font(.body.monospacedDigit()).textFieldStyle(.roundedBorder)
            .focused($focused).submitLabel(.done)
            .onSubmit { if commit() { focused = false } }
            .accessibilityIdentifier("numeric-field-" + label)
            .accessibilityLabel(label + (english ? " value" : " 数值"))
            #if os(iOS)
            .keyboardType(.numbersAndPunctuation)
            #endif
    }

    private var sliderValue: Binding<Double> {
        Binding(get: { Double(value) }, set: { number in
            guard number.isFinite else { return }
            let proposed = Float(number)
            guard proposed.isFinite, configuration.range.contains(proposed) else { return }
            value = proposed
            refreshDraft()
        })
    }

    @discardableResult private func commit() -> Bool {
        do {
            let proposed = try NumericAxisInput.parse(draft, unit: unit, range: configuration.range, locale: locale)
            // Merely focusing or switching units must not round/write a model value.
            if changed { value = proposed }
            refreshDraft(); onValidityChanged(true)
            return true
        } catch { onValidityChanged(false); return false }
    }

    private func refreshDraft() {
        draft = NumericAxisInput.text(for: value, unit: unit)
        onValidityChanged(configuration.range.contains(value) && value.isFinite)
    }
}
