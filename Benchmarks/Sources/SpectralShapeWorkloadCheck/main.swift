import Foundation
import SpectralShapeWorkload

let cases = try ShapeCase.matrix()
for item in cases {
    let trial = try ShapeTrial(item)
    for op in ShapeOperation.allCases {
        try trial.prepare(op)
        try trial.run(op)
        try trial.verify(op)
    }
}
FileHandle.standardOutput.write(try JSONEncoder().encode(cases))
