import CoreGraphics
import Foundation
import AmbitCore

// Pure time-series geometry, harvested from pingscope's LatencyGraph Canvas math. Kept
// separate from the View so it is unit-testable and reusable by every graph card.
public struct GraphSeriesGeometry: Equatable, Sendable {
    public var segments: [[CGPoint]]
    public var failureXPositions: [CGFloat]

    public init(segments: [[CGPoint]] = [], failureXPositions: [CGFloat] = []) {
        self.segments = segments
        self.failureXPositions = failureXPositions
    }
}

public enum GraphGeometry {

    // Scale-invariant "nice" ceiling: a mantissa rung × the data's order of magnitude. Works
    // for any unit (ms, bps, %, °C) — replaces the latency-only rung ladder.
    private static let mantissas: [Double] = [1, 1.5, 2, 2.5, 3, 5, 7.5, 10]

    /// Smallest "nice" ceiling at or above the max value; 100 when there is no positive data.
    public static func niceMax(_ values: [Double]) -> Double {
        guard let maxValue = values.max(), maxValue > 0 else { return 100 }
        let exponent = (log10(maxValue)).rounded(.down)
        let base = pow(10, exponent)
        for mantissa in mantissas where mantissa * base >= maxValue {
            return mantissa * base
        }
        return 10 * base
    }

    /// Sample series mapped into a box: x spreads evenly across width, y inverts value/axisMax.
    /// Missing values render as 0 (bottom), matching the harvested LatencyGraph behavior.
    public static func points(samples: [Sample], in size: CGSize, axisMax: Double) -> [CGPoint] {
        guard samples.count > 1, axisMax > 0 else {
            if samples.count == 1 {
                let value = samples[0].value ?? 0
                let y = size.height * (1 - min(value / max(axisMax, 1), 1))
                return [CGPoint(x: 0, y: y)]
            }
            return []
        }
        return samples.enumerated().map { index, sample in
            let x = size.width * Double(index) / Double(samples.count - 1)
            let value = sample.value ?? 0
            let y = size.height * (1 - min(value / axisMax, 1))
            return CGPoint(x: x, y: y)
        }
    }

    /// Sample series mapped into drawable line segments plus failure markers. Failed samples
    /// (`value == nil` or `ok == false`) split the line and never become zero-valued points.
    public static func series(
        samples: [Sample],
        in size: CGSize,
        axisMax: Double,
        plotVerticalPadding: CGFloat = 0
    ) -> GraphSeriesGeometry {
        guard !samples.isEmpty, axisMax > 0 else { return GraphSeriesGeometry() }

        let denominator = CGFloat(max(samples.count - 1, 1))
        let plotTop = plotVerticalPadding
        let plotHeight = max(size.height - plotVerticalPadding * 2, 1)
        var segments: [[CGPoint]] = []
        var current: [CGPoint] = []
        var failures: [CGFloat] = []

        func flushSegment() {
            guard !current.isEmpty else { return }
            segments.append(current)
            current.removeAll(keepingCapacity: true)
        }

        for (index, sample) in samples.enumerated() {
            let x = size.width * CGFloat(index) / denominator
            guard sample.ok, let value = sample.value else {
                failures.append(x)
                flushSegment()
                continue
            }

            let normalized = min(max(value / axisMax, 0), 1)
            let y = plotTop + plotHeight - (plotHeight * CGFloat(normalized))
            current.append(CGPoint(x: x, y: y))
        }
        flushSegment()

        return GraphSeriesGeometry(segments: segments, failureXPositions: failures)
    }
}
