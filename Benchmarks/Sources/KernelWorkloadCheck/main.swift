import Foundation

#if KernelBenchmarks
    import KernelWorkload

    func profile(_ name: String, matrix: [KernelCase]) throws {
        let supported: [KernelOperation] = [
            .meanRemoval, .logPower, .inverseCepstrum, .peakParabolic, .backgroundFit,
        ]
        guard let op = supported.first(where: { $0.rawValue == name }),
            let item = matrix.first(where: {
                $0.operation == op && $0.sourceRate == 10_000 && !$0.nearFloor
                    && (op != .backgroundFit || $0.fitMethod == .praat7002Robust)
            })
        else { throw KernelError.invalidPlan }
        let record = try KernelRecord(item)
        let batch = try KernelBatch(record)
        let clock = ContinuousClock()
        let until = clock.now.advanced(by: .seconds(3))
        var batches = 0
        repeat {
            batch.reset()
            try batch.verify(batch.run())
            batches += 1
        } while clock.now < until
        print(
            "\(record.name) \(batches) verified batches of \(record.operationsPerBatch) operations")
    }

    let matrix = try KernelCase.matrix()
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.count == 2 && arguments[0] == "--profile" {
        try profile(arguments[1], matrix: matrix)
    } else if arguments.isEmpty {
        let records = try matrix.map { item in
            let record = try KernelRecord(item)
            let batch = try KernelBatch(record)
            for _ in 0..<2 {
                batch.reset()
                try batch.verify(batch.run())
            }
            return record
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(records))
    } else {
        throw KernelError.invalidPlan
    }
#else
    FileHandle.standardError.write(Data("Enable the KernelBenchmarks trait.\n".utf8))
    exit(2)
#endif
