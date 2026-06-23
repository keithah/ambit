import SwiftUI
import AmbitCore

/// toggle / select / number / button, chosen from the entity's kind. Commands are dispatched
/// by the host through the supplied closures (the host owns the Engine).
public struct ControlCard: View {
    let descriptor: EntityDescriptor
    let state: EntityState?
    let onToggle: (Bool) -> Void
    let onSelect: (String) -> Void
    let onButton: () -> Void
    let onNumber: (Double) -> Void

    public init(descriptor: EntityDescriptor, state: EntityState?,
                onToggle: @escaping (Bool) -> Void = { _ in },
                onSelect: @escaping (String) -> Void = { _ in },
                onButton: @escaping () -> Void = {},
                onNumber: @escaping (Double) -> Void = { _ in }) {
        self.descriptor = descriptor
        self.state = state
        self.onToggle = onToggle
        self.onSelect = onSelect
        self.onButton = onButton
        self.onNumber = onNumber
    }

    private var boolValue: Bool {
        if case .bool(let b)? = state?.value { return b }
        return false
    }
    private var textValue: String {
        if case .text(let s)? = state?.value { return s }
        return ""
    }
    private var numberValue: Double {
        if case .number(let n)? = state?.value { return n }
        return descriptor.range?.min ?? 0
    }

    public var body: some View {
        HStack {
            Text(descriptor.name).font(.system(size: 13))
            Spacer()
            switch descriptor.kind {
            case .toggle:
                Toggle("", isOn: Binding(get: { boolValue }, set: onToggle)).labelsHidden()
            case .select:
                Picker("", selection: Binding(get: { textValue }, set: onSelect)) {
                    ForEach(descriptor.options ?? [], id: \.value) { option in
                        Text(option.label).tag(option.value)
                    }
                }
                .labelsHidden().fixedSize()
            case .number:
                Stepper(value: Binding(get: { numberValue }, set: onNumber),
                        in: (descriptor.range?.min ?? 0)...(descriptor.range?.max ?? 100),
                        step: descriptor.range?.step ?? 1) {
                    Text(String(Int(numberValue))).font(.system(.body, design: .monospaced))
                }
                .fixedSize()
            case .button:
                Button(descriptor.name, action: onButton)
            case .sensor, .binarySensor, .text:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
    }
}
