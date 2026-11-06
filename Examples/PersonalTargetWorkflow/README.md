# Personal target workflow

This separate SwiftPM executable imports only the public core library. It loads
nine independently calculated **synthetic summary scenarios**, imports their
bounded analysis records, freezes training-only CPPS candidates, and evaluates
whole-recording and later-session holdouts. It also fits/evaluates the maximum
512-take, 32-session dataset repeatedly and exports the small activated model.

Run through the audited evidence driver from the repository root:

```sh
python3 Tools/PersonalTargets/evidence.py --output .build/personal-target-evidence
```

The driver first verifies committed independent expectations and runs the actual
exact-profile PCM/reference/chunk/boundary test. Only a successful test process
and a fully validated report produce the checked evidence envelope consumed here.
It then builds this example in Release, runs twenty fresh processes and independently
checks every scenario's bounds, direction, predictions, confusion counts, conditional
uncertainty, identities and activation/refusal. Eleven deliberately corrupted
artifacts must fail. Native outputs are retained for review; no private recording
or microphone is used, and the runner does not download Praat.

The model inputs here are fabricated numerical summaries, not results of a listening
study. The DSP evidence uses actual synthetic PCM separately. Labels were assigned
after role selection only to construct balanced software scenarios. This is not a
recording protocol or evidence that the model is useful for any person's voice.
For real file analysis, use the public `CalibrationFileAnalysisBatch` illustrated
by [CalibrationWorkflow](../CalibrationWorkflow/README.md), preserve listening
labels and acquisition provenance, and supply exact-profile validation receipts.

Each maximum-count pass times fitting and evaluation separately, including their
validation, hashing, grouping and report construction. Input construction/import
and output-file writes are outside these intervals. Process peak RSS includes the
runtime, nine small scenarios, prepared maximum-count input and report serialization.
The driver compares ten fresh processes with one pass to ten with four passes;
median growth may not exceed the declared 32 MiB host smoke allowance. These are
offline host measurements, not a callback allocation guarantee, physical-device
budget, or a maximum-16-MiB-metadata stress test. Every model must encode within
64 KiB and repeated fitting must retain its identity.

The output includes datasets, splits, fits, evaluations, validation/source digests,
timings and model artifacts, all made solely from named synthetic fixtures. Do not
replace those inputs with private recordings and publish the resulting artifacts.
The target's scope and limitations are documented in
[Personal targets](../../Documentation/PersonalTargets.md).
