import FormantWorkload
import Foundation

#if KernelBenchmarks
    let cases = try FormantCase.matrix()
    for item in cases {
        let trial = try FormantTrial(item)
        for operation in FormantOperation.allCases {
            trial.prepare()
            try trial.run(operation)
            trial.verify()
        }
    }
    FileHandle.standardOutput.write(try JSONEncoder().encode(cases))
#else
    FileHandle.standardError.write(
        Data("FormantWorkloadCheck requires the KernelBenchmarks trait.\n".utf8))
    exit(2)
#endif
