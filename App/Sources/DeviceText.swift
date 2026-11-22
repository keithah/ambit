import AmbitKit
import SwiftUI

/// Wording shared by the device rows and detail pages.
enum DeviceText {
    /// One sentence for a condition that is not "online". `noun` is "dish" or "router".
    static func problem(_ condition: DeviceCondition, noun: String) -> String? {
        switch condition {
        case .loading: "Checking…"
        case .online: nil
        case .stale(let lastSeen): "Last seen \(lastSeen.formatted(.relative(presentation: .numeric)))."
        case .unreachable: "Can't reach the \(noun). Check that you're on its network."
        case .passwordNeeded: "Enter the \(noun)'s admin password."
        case .wrongPassword: "Wrong password. Enter the \(noun)'s admin password."
        case .lockedOut(let until): "Too many wrong passwords. The \(noun) accepts a new try at \(until.formatted(date: .omitted, time: .shortened))."
        case .unexpectedReply: "The \(noun) sent a reply Ambit can't read."
        }
    }

    static func color(_ condition: DeviceCondition) -> Color {
        switch condition {
        case .loading: .secondary
        case .online: .green
        case .stale: .orange
        case .unreachable, .passwordNeeded, .wrongPassword, .lockedOut, .unexpectedReply: .red
        }
    }

    static func megabits(_ bitsPerSecond: Double?) -> String {
        guard let bitsPerSecond else { return "–" }
        let value = bitsPerSecond / 1_000_000
        return value < 10 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }

    static func uptime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–" }
        return Duration.seconds(seconds.rounded()).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
    }
}

/// A label and a value on one line of a detail page.
struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 13))
        .accessibilityElement(children: .combine)
    }
}

/// A button that asks once more, in place, before it acts. A popover closes when a dialog opens,
/// so the question is asked inside the popover.
struct ConfirmedButton: View {
    let title: String
    let question: String
    let action: () async -> Void
    @State private var asking = false
    @State private var working = false

    var body: some View {
        if asking {
            HStack {
                Text(question).font(.system(size: 13))
                Spacer()
                Button("Cancel") { asking = false }
                Button(title) {
                    asking = false
                    working = true
                    Task {
                        await action()
                        working = false
                    }
                }
            }
        } else {
            Button(title) { asking = true }
                .disabled(working)
        }
    }
}
