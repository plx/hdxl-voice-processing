import Foundation
import SmokeWorkload

let workload = try GainEnergyWorkload()
let initialChecksum = workload.checksum
let energy = workload.run()
precondition(initialChecksum != workload.checksum, "The workload must write its output buffer")
precondition(workload.checksum == GainEnergyWorkload.expectedChecksum)
precondition(energy == GainEnergyWorkload.expectedEnergy)

#if AllocationDiagnostics
    let mode = "allocation"
#else
    let mode = "timing"
#endif

let report: [String: Any] = [
    "schemaVersion": 1,
    "mode": mode,
    "workload": "benchmark-only gain 0.5 and energy / 1024 Float64 samples",
    "sampleRate": workload.format.sampleRate,
    "channelCount": workload.format.channelCount,
    "encoding": workload.format.encoding.rawValue,
    "layout": workload.format.layout.rawValue,
    "framesPerBatch": GainEnergyWorkload.framesPerBatch,
    "samplesPerFrame": workload.input.count,
    "outputChecksum": workload.checksum,
    "energy": energy,
    "outputChanged": initialChecksum != workload.checksum,
]
let data = try JSONSerialization.data(
    withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
