# Synthetic calibration workflow

This macOS 27 / Swift 6.4 command-line example consumes the public Core and Audio
products from a separate Swift package. It makes no microphone request or network
download. The committed fixtures are generated integer PCM, not human recordings.
Task names exercise metadata; the waveforms do not contain spoken vowels, sentences
or passages. Listening labels are scripted examples, not listening-study evidence.

From the repository root, choose a new output directory:

```sh
python3 Tools/Calibration/generate.py verify --directory Tests/HDXLVoiceProcessingTests/Fixtures/Calibration
swift run --package-path Examples/CalibrationWorkflow -c release CalibrationWorkflow \
  Tests/HDXLVoiceProcessingTests/Fixtures/Calibration .build/calibration-example
```

The example creates an unlabeled dataset, shuffles opaque replay tokens, submits
scripted listening labels, completes a new revision, freezes recording/session
assignments, then analyzes the audio. A preferred instruction deliberately receives
a usual label; other and uncertain labels also remain explicit. Original level and
pitch differences are retained.

Inspect `replay-presenter.json`, `dataset.json`, `split.json`, the per-take
`analysis-*.json` cache records, and `report.json`. The report separates 12 takes in
the first session from four novel-task takes in an untouched evaluation session.
Within-session comparisons retain task/prompt, instruction, actual label, split,
coverage and raw metric summaries rather than combining different tasks into one
score. Unknown physical microphone distance is reported honestly for synthetic
audio. No fit, preference direction, clinical threshold or human measurement is claimed.

For bounded import evidence, the command also imports a 32-session/512-take stress
dataset ten times. Those takes alias the 16 fixtures; they are not independent
observations and are never used for fitting/evaluation. File-analysis timing includes
snapshot hashing, decoder preparation, numerical work, summary construction and
validation. A separate cache pass still verifies audio bytes but decodes zero PCM.

An optional final argument `1...8` repeats fresh analysis of all 16 recordings. Only
one latest cache record per take is retained. Per-pass evidence includes source/file
denominators, chunk and scalar bounds, sampled prepared buffers, elapsed time, and
macOS process peak RSS. RSS is a cumulative process high-water mark including the
import stress and runtime/decoder overhead, not a count of live DSP buffers or a
physical iPhone measurement. Temporary verified audio copies are removed after each
input; a private scratch directory is explicitly provided to the Audio API.

See [the calibration guide](../../Documentation/Calibration.md) for API semantics,
limits, cache trust, blinding boundaries and references. Target fitting is #53.
