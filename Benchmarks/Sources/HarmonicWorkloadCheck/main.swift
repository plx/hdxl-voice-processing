import Foundation
import HarmonicWorkload

var rows: [HarmonicTrial.Observation] = []
for item in try HarmonicCase.matrix() {
    let trial = try HarmonicTrial(item)
    for operation in HarmonicOperation.allCases {
        trial.prepare()
        try trial.run(operation)
        try trial.verify(operation)
    }
    rows.append(try trial.observation())
}
FileHandle.standardOutput.write(try JSONEncoder().encode(rows))
