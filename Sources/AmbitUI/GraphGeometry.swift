import CoreGraphics
import Foundation
import AmbitCore

// Pure time-series geometry, harvested from pingscope's LatencyGraph Canvas math. Kept
// separate from the View so it is unit-testable and reusable by every graph card.
public enum GraphGeometry {

    private static let ladder: [Double] = [50, 100, 150, 200, 300, 500, 750, 1000, 1500, 2000, 3000, 5000]

    /// Smallest "nice" ceiling at or above the max value; 100 when there is no positive data.
    public static func niceMax(_ values: [Double]) -> Double {
        guard let maxValue = values.max(), maxValue > 0 else { return 100 }
        if let step = ladder.first(where: { $0 >= maxValue }) { return step }
        return (maxValue / 1000).rounded(.up) * 1000
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
}
