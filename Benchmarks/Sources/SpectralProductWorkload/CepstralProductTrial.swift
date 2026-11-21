import Foundation
import HDXLVoiceProcessing

public enum CepstralProductOperation: String, CaseIterable, Sendable {
    case generate = "CepGenerate"
    case retain8 = "CepRetain8"
    case retain64 = "CepRetain64"
    case export = "CepExport"
    var capacity: Int { self == .retain64 ? 64 : 8 }
}

public final class CepstralProductTrial {
    let item: ProductCase
    let input: [Double]
    let frames: [PowerCepstrumFrame]
    let expectedSum: Double
    var generator: PreparedPreviewCepstrogram<Double>?
    var ring: RollingSpectralProducts?
    var lastCopy: [Double] = []
    var count = 0
    var sum = 0.0

    public init(_ item: ProductCase) throws {
        self.item = item
        input = (0..<item.inputSamples).map(ProductCase.sample)
        let prepared = try PreparedPreviewCepstrogram<Double>(
            configuration: item.cepstrogram, epoch: item.source.epoch)
        let exporter = try PowerCepstrogramExporter(configuration: item.cepstrogram)
        var rows: [PowerCepstrumFrame] = []
        rows.reserveCapacity(item.expectedCepstralFrames)
        let emit: (BorrowedPowerCepstrum<Double>) -> Void = { rows.append(try! exporter.owned($0)) }
        _ = try input.withUnsafeBufferPointer {
            try prepared.process($0, interval: item.source, emit: emit)
        }
        _ = try prepared.finish(emit: emit)
        precondition(
            rows.count == item.expectedCepstralFrames
                && rows.last?.unavailability == .insufficientData)
        frames = rows
        expectedSum = rows.reduce(0) { $0 + ($1.values.first ?? 0) }
        precondition(expectedSum.isFinite && expectedSum > 0)
    }

    public func prepare(_ operation: CepstralProductOperation) throws {
        count = 0
        sum = 0
        lastCopy = []
        switch operation {
        case .generate:
            generator = try PreparedPreviewCepstrogram(
                configuration: item.cepstrogram, epoch: item.source.epoch)
        case .retain8, .retain64:
            ring = try RollingSpectralProducts(
                configuration: item.cepstrogram, capacity: operation.capacity)
        case .export: break
        }
    }

    @inline(never) public func run(_ operation: CepstralProductOperation) throws {
        switch operation {
        case .generate:
            let emit: (BorrowedPowerCepstrum<Double>) -> Void = { row in
                self.sum += row.stage(.powerCepstrum).values.first ?? 0
                self.count += 1
            }
            let generator = generator!
            _ = try input.withUnsafeBufferPointer {
                try generator.process($0, interval: item.source, emit: emit)
            }
            _ = try generator.finish(emit: emit)
        case .retain8, .retain64:
            let ring = ring!
            for row in frames { try ring.append(row) }
        case .export:
            for row in frames {
                lastCopy = row.values.withUnsafeBufferPointer { Array($0) }
                sum += lastCopy.first ?? 0
                count += 1
            }
        }
    }

    public func verify(_ operation: CepstralProductOperation) {
        switch operation {
        case .generate, .export:
            precondition(count == frames.count && sum == expectedSum)
        case .retain8, .retain64:
            let kept = min(operation.capacity, frames.count)
            let snapshot = ring!.snapshot()
            precondition(snapshot.evictedCount == UInt64(frames.count - kept))
            precondition(
                snapshot.columns == frames.suffix(kept).map(SpectralProductColumn.powerCepstrum))
        }
    }
}
