import CoreGraphics
import SwiftUI

/// Prepare the fixed-history intensity raster once, including transparent unavailable bins.
struct AcousticIntensityColumn: Sendable {
    let image: CGImage?

    init(column: AcousticPlotPayload, bins: Int, range: ClosedRange<Double>?) {
        guard let range, column.unavailability == nil else {
            image = nil
            return
        }
        let scale = AcousticPlotScale(bounds: range)
        var bytes = [UInt8](repeating: 0, count: bins * 4)
        for i in 0..<bins {
            guard let v = column.value(at: i) else { continue }
            let f = scale.fraction(v)
            let j = (bins - 1 - i) * 4
            // Monotonic luminance, from deep blue through teal to pale gold.
            bytes[j] = UInt8(18 + 222 * f * f)
            bytes[j + 1] = UInt8(42 + 188 * f)
            bytes[j + 2] = UInt8(71 + 59 * f)
            bytes[j + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)
        image = provider.flatMap {
            CGImage(
                width: 1, height: bins, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
}

struct AcousticPlotDrawing: View {
    let data: AcousticPlotData
    let horizontal: AcousticPlotScale
    let vertical: AcousticPlotScale
    let selection: VisualizationSelection?
    let focused: AcousticPlotIndex?
    let envelope: Bool

    var body: some View {
        Canvas { ctx, size in
            guard size.width > 0 && size.height > 0 else { return }
            let geometry = AcousticPlotVerticalGeometry(scale: vertical, viewHeight: size.height)
            let top = geometry.top
            let height = geometry.height
            func x(_ v: Double) -> Double { 4 + horizontal.fraction(v) * max(1, size.width - 8) }
            func y(_ v: Double) -> Double { geometry.y(v) }
            func line(
                _ a: CGPoint, _ b: CGPoint, _ color: Color, _ width: CGFloat = 1,
                dash: [CGFloat] = []
            ) {
                var p = Path()
                p.move(to: a)
                p.addLine(to: b)
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, dash: dash))
            }
            func region(_ low: Double, _ high: Double, _ color: Color) {
                guard high >= horizontal.bounds.lowerBound, low <= horizontal.bounds.upperBound
                else { return }
                ctx.fill(
                    Path(
                        CGRect(x: x(low), y: top, width: max(1, x(high) - x(low)), height: height)),
                    with: .color(color))
            }
            func missing(_ at: Double) {
                guard horizontal.bounds.contains(at) else { return }
                let xx = x(at)
                let yy = geometry.missingY
                line(CGPoint(x: xx - 3, y: yy - 3), CGPoint(x: xx + 3, y: yy + 3), .secondary, 1.5)
                line(CGPoint(x: xx + 3, y: yy - 3), CGPoint(x: xx - 3, y: yy + 3), .secondary, 1.5)
            }

            for tick in [0.0, 0.5, 1.0] {
                let yy = top + tick * height
                line(
                    CGPoint(x: x(horizontal.bounds.lowerBound), y: yy),
                    CGPoint(x: x(horizontal.bounds.upperBound), y: yy), .secondary.opacity(0.35),
                    0.6)
            }
            if data.kind != .spectrum {
                for gap in data.boundaries {
                    if let interval = gap.missingSource,
                        let span = try? data.timeAxis.placement(of: interval)
                    {
                        region(span.lowerSeconds, span.upperSeconds, .secondary.opacity(0.16))
                        missing(span.centerSeconds)
                    }
                }
            }
            switch data.kind {
            case .metric:
                for (index, column) in data.columns.enumerated()
                where horizontal.bounds.contains(data.centers[index]) {
                    let t = data.centers[index]
                    if let value = column.value(at: 0) {
                        let rect = CGRect(x: x(t) - 2.8, y: y(value) - 2.8, width: 5.6, height: 5.6)
                        ctx.fill(Path(ellipseIn: rect), with: .color(.teal))
                    } else {
                        missing(t)
                    }
                }
            case .spectrogram, .cepstrogram:
                for (i, center) in data.centers.enumerated() {
                    guard let bounds = data.imageCell(at: i) else { continue }
                    let left = bounds.lowerBound
                    let right = bounds.upperBound
                    guard right >= horizontal.bounds.lowerBound,
                        left <= horizontal.bounds.upperBound
                    else { continue }
                    if let image = data.intensities[i].image {
                        let halfBin =
                            data.binCount > 1 ? height / Double(2 * (data.binCount - 1)) : 0
                        let cell = CGRect(
                            x: x(left), y: top, width: max(0.5, x(right) - x(left)), height: height)
                        var raster = ctx
                        raster.clip(to: Path(cell))
                        raster.draw(
                            Image(decorative: image, scale: 1).interpolation(.none),
                            in: cell.insetBy(dx: 0, dy: -halfBin))
                    } else {
                        missing(center)
                    }
                }
            case .waveform, .spectrum:
                if let column = data.columns.first,
                    let a = data.nearestIndex(x: horizontal.bounds.lowerBound, ordinate: 0),
                    let b = data.nearestIndex(x: horizontal.bounds.upperBound, ordinate: 0)
                {
                    let bins = min(a.bin, b.bin)..<(max(a.bin, b.bin) + 1)
                    if column.unavailability != nil {
                        missing(horizontal.value(0.5))
                    } else if data.kind == .waveform && envelope,
                        let buckets = try? data.envelope(
                            bins: bins, maximumBuckets: max(1, Int(min(4096, size.width))))
                    {
                        for bucket in buckets {
                            let bin = bucket.bins.lowerBound + bucket.bins.count / 2
                            guard let t = data.coordinate(of: .init(column: 0, bin: bin)) else {
                                continue
                            }
                            let xx = x(t)
                            let low = y(bucket.minimum)
                            let high = y(bucket.maximum)
                            line(CGPoint(x: xx, y: high - 0.5), CGPoint(x: xx, y: low + 0.5), .teal)
                        }
                    } else {
                        var path = Path()
                        var previous = false
                        for bin in bins {
                            guard let t = data.coordinate(of: .init(column: 0, bin: bin)) else {
                                continue
                            }
                            if let value = column.value(at: bin) {
                                let p = CGPoint(x: x(t), y: y(value))
                                if previous {
                                    path.addLine(to: p)
                                } else {
                                    path.move(to: p)
                                    ctx.fill(
                                        Path(
                                            ellipseIn: CGRect(
                                                x: p.x - 1, y: p.y - 1, width: 2, height: 2)),
                                        with: .color(.teal))
                                }
                                previous = true
                            } else {
                                previous = false
                                missing(t)
                            }
                        }
                        ctx.stroke(path, with: .color(.teal), lineWidth: 1.5)
                    }
                }
            }

            for marker in data.markers where horizontal.bounds.contains(marker.coordinate) {
                let xx = x(marker.coordinate)
                let pulse = marker.kind == .eligiblePulse || marker.kind == .rejectedPulse
                let length = pulse ? height * 0.14 : height * 0.8
                let dash: [CGFloat]
                switch marker.kind {
                case .harmonic, .eligiblePulse: dash = []
                case .formant, .rejectedPulse: dash = [4, 3]
                case .spectralMeasure: dash = [1, 3]
                }
                line(
                    CGPoint(x: xx, y: top), CGPoint(x: xx, y: top + length), .indigo, 1.5,
                    dash: dash)
            }
            if data.kind != .spectrum, let selection,
                let span = try? data.timeAxis.placement(of: selection.source)
            {
                if selection.source.sampleCount > 0 {
                    region(span.lowerSeconds, span.upperSeconds, .indigo.opacity(0.12))
                }
                if horizontal.bounds.contains(span.centerSeconds) {
                    let xx = x(span.centerSeconds)
                    line(
                        CGPoint(x: xx, y: top), CGPoint(x: xx, y: top + height), .primary, 1,
                        dash: [3, 3])
                }
            }
            if let focused, let t = data.coordinate(of: focused), horizontal.bounds.contains(t) {
                let v =
                    data.kind.isImage
                    ? Double(focused.bin) * data.binStep
                    : data.columns[focused.column].value(at: focused.bin)
                if let v {
                    let rect = CGRect(x: x(t) - 4, y: y(v) - 4, width: 8, height: 8)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.primary), lineWidth: 1.5)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
