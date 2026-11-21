# DSP kernel measurement evidence

The paired release run produces `kernels.csv` with one row per calibrated workload. Its case records identify the precision, source geometry, operation count and scalar reference. Its timing and allocator manifests identify the raw distributions and percentile exports. [Reproduction instructions and operation boundaries](../../Tools/Kernels/README.md)

## Synthetic Instruments attribution

On an arm64 Mac with macOS 27.0.1 and Xcode 27.2 (27B52), Time Profiler sampled five separately launched release workloads at 10 kHz analysis rate. Each process checked its numerical result on every batch for three seconds. The total includes launch, setup, verification and shutdown samples from that target process. The attributed count counts a stack once when it contains a recognized production symbol. These counts verify which code ran during the probe.

| Workload | Target-process stacks | Attributed stacks | Production symbol observed |
| --- | ---: | ---: | --- |
| Compensated mean removal | 3,009 | 2,983 | `removeMean` |
| Log power | 3,010 | 2,987 | `writeLogPower` |
| Inverse real cepstrum | 3,011 | 2,990 | `writeSignedCepstrum` |
| Parabolic peak search | 3,010 | 2,975 | `PreparedCPP.peakFromSide` |
| Praat robust background fit | 3,009 | 2,992 | `PreparedCPP.fit`, `CPPSelection` |

This development capture used synthetic data and executable SHA-256 `bb3aa47e3a72453aebc19cfc121bec76fde51705d0a47aa5b38f56e648d0c928`. A controlled hardware baseline, repeated acquisition with monitored thermal conditions and any resulting budget changes are pending in the follow-up epic. [Physical collection and adjustment protocol](https://github.com/plx/hdxl-voice-processing/issues/74#issuecomment-7062138635)
