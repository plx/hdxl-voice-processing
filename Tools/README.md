# Development tools

Run `bash Tools/verify.sh` for local checks and `bash Tools/build-ios.sh` for
unsigned iOS simulator builds. Formatting uses `bash Tools/format.sh --write`.
Reference generation will be isolated here; none of these tools is a consumer
dependency or invoked implicitly during runtime analysis.

[The cepstral tools](Cepstrum/README.md) generate independent pinned-Praat stage references,
verify committed fixtures offline, and measure the prepared PCM-to-power-cepstrum paths with
separate conversion/export costs. Candidate generation never overwrites reviewed fixtures.
