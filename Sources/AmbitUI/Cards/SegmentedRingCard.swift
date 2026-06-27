import SwiftUI
import AmbitCore

/// A generic proportional ring for sibling metrics that form parts of a whole.
public struct SegmentedRingCard: View {
    public struct Model: Equatable {
        public struct Segment: Identifiable, Equatable {
            public var id: String
            public var label: String
            public var value: Double
            public var fraction: Double
            public var readout: String
            public var tone: DisplayTone

            public init(id: String, label: String, value: Double, fraction: Double, readout: String, tone: DisplayTone = .neutral) {
                self.id = id
                self.label = label
                self.value = value
                self.fraction = fraction
                self.readout = readout
                self.tone = tone
            }
        }

        public var segments: [Segment]
        public var remainder: Segment?
        public var total: Double?
        public var centerReadout: String?
        public var isIncomplete: Bool

        public init(segments: [Segment], remainder: Segment? = nil, total: Double? = nil, centerReadout: String? = nil, isIncomplete: Bool = false) {
            self.segments = segments
            self.remainder = remainder
            self.total = total
            self.centerReadout = centerReadout
            self.isIncomplete = isIncomplete
        }

        public init(entityIDs: [EntityID], data: SurfaceData) {
            let raw = entityIDs.map { id -> (EntityID, EntityDescriptor, EntityState, Double)? in
                guard let descriptor = data.descriptors[id], let state = data.states[id] else { return nil }
                guard state.availability == .online else { return nil }
                guard case .number(let value)? = state.value, value.isFinite, value >= 0 else { return nil }
                return (id, descriptor, state, value)
            }
            guard raw.allSatisfy({ $0 != nil }) else {
                self.segments = []
                self.remainder = nil
                self.total = nil
                self.centerReadout = nil
                self.isIncomplete = true
                return
            }
            let members = raw.compactMap { $0 }
            let explicitTotal = members.first { $0.1.compositionRole == .total }
            let total = explicitTotal?.3 ?? members
                .filter { $0.1.compositionRole != .total }
                .reduce(0) { $0 + $1.3 }
            guard total > 0 else {
                self.segments = []
                self.remainder = nil
                self.total = nil
                self.centerReadout = nil
                self.isIncomplete = true
                return
            }
            func segment(from member: (EntityID, EntityDescriptor, EntityState, Double)) -> Segment {
                let readout = EntityReadout.make(descriptor: member.1, state: member.2)
                return Segment(
                    id: member.0.rawValue,
                    label: member.1.name,
                    value: member.3,
                    fraction: Swift.min(Swift.max(member.3 / total, 0), 1),
                    readout: readout.text,
                    tone: readout.tone
                )
            }
            let colored = members.filter { member in
                let role = member.1.compositionRole ?? .segment
                return role == .segment
            }
            let remainder = members.first { $0.1.compositionRole == .remainder }.map(segment)
            let center = members.first { $0.1.compositionRole == .total && $0.1.isPrimary }
                ?? members.first { $0.1.isPrimary && ($0.1.compositionRole ?? .segment) != .remainder }
                ?? colored.first
            let centerSibling = Self.primaryPercentSibling(for: members, data: data)
            self.segments = colored.map(segment)
            self.remainder = remainder
            self.total = total
            if let centerSibling {
                self.centerReadout = EntityReadout.make(descriptor: centerSibling.0, state: centerSibling.1).text
            } else if let remainder {
                let usedFraction = Swift.min(Swift.max(1 - remainder.fraction, 0), 1)
                self.centerReadout = EntityReadout.format(usedFraction * 100, deviceClass: .percent, unit: "%")
            } else {
                self.centerReadout = center.map { EntityReadout.make(descriptor: $0.1, state: $0.2).text }
            }
            self.isIncomplete = false
        }

        private static func primaryPercentSibling(
            for members: [(EntityID, EntityDescriptor, EntityState, Double)],
            data: SurfaceData
        ) -> (EntityDescriptor, EntityState)? {
            guard let capability = members.first?.1.capability else { return nil }
            let memberIDs = Set(members.map(\.0))
            let candidates = data.descriptors.values.filter { descriptor in
                guard !memberIDs.contains(descriptor.id) else { return false }
                guard descriptor.capability == capability else { return false }
                guard descriptor.isPrimary else { return false }
                guard descriptor.graphStyle == .progress else { return false }
                return descriptor.deviceClass == .percent || descriptor.deviceClass == .battery
            }
            for descriptor in candidates.sorted(by: { ($0.priority ?? Int.min) > ($1.priority ?? Int.min) }) {
                guard
                    let state = data.states[descriptor.id],
                    state.availability == .online,
                    case .number(let value)? = state.value,
                    value.isFinite
                else { continue }
                return (descriptor, state)
            }
            return nil
        }
    }

    let title: String?
    let model: Model

    public init(title: String? = nil, model: Model) {
        self.title = title
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title, !title.isEmpty {
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            HStack(alignment: .center, spacing: 13) {
                ZStack {
                    ring
                    if let center = model.centerReadout {
                        Text(center)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                }
                .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(model.segments.enumerated()), id: \.element.id) { index, segment in
                        HStack(spacing: 7) {
                            Circle().fill(Theme.lineColor(index)).frame(width: 7, height: 7)
                            Text(segment.label).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(segment.readout).font(.system(size: 11.5, design: .monospaced))
                        }
                    }
                }
            }
        }
        .cardChrome()
    }

    private var ring: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)
            let lineWidth: CGFloat = 9
            var track = Path()
            track.addArc(
                center: CGPoint(x: rect.midX, y: rect.midY),
                radius: min(rect.width, rect.height) / 2,
                startAngle: .degrees(-90),
                endAngle: .degrees(270),
                clockwise: false
            )
            context.stroke(track, with: .color(.white.opacity(model.remainder == nil ? 0.08 : 0.14)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            var start = Angle(degrees: -90)
            for (index, segment) in model.segments.enumerated() where segment.fraction > 0 {
                let end = start + Angle(degrees: 360 * segment.fraction)
                var path = Path()
                path.addArc(
                    center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) / 2,
                    startAngle: start,
                    endAngle: end,
                    clockwise: false
                )
                context.stroke(path, with: .color(Theme.lineColor(index)), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                start = end
            }
        }
    }
}
