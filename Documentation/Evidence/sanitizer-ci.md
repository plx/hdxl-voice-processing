# Optimized sanitizer correctness lanes

Required infrastructure follow-up [#114](https://github.com/plx/hdxl-voice-processing/issues/114)
was discovered while validating CPPS in #37 / PR #113. It preserves every test and
numerical budget while changing sanitizer compilation from debug to release.
Ordinary debug and uninstrumented release lanes remain distinct and complete.
The configuration recorded in evidence and passed to SwiftPM has one shared source.

## Why this change is necessary

On Mac13,1, arm64, macOS 27.0.1, Xcode 27.0 (27A266a), Swift 6.4 and Python 3.14.8,
the same 18 isolated CPPS reference cases (222 frames) passed in:

| Instrumentation | Debug seconds | Optimized seconds |
| --- | ---: | ---: |
| AddressSanitizer | 676.734 | 1.902 |
| ThreadSanitizer | 422.788 | 23.294 |

These are development observations under concurrent activity, not controlled
performance baselines or a speedup guarantee. They establish that debug sanitizer
execution is impractical for the complete CPPS reference set. The ordinary debug
CPPS frame comparison still runs in full: it passed in 1,634.884 seconds. The
ordinary release comparison passed in 113.145 seconds.

The complete CPPS-stage suite subsequently passed with optimized AddressSanitizer:
176 reported cases, zero failures/errors; the full PCM CPPS comparison took
103.001 seconds. This integration run used CPPS candidate `7038a1fd1a`, including
its delay regression. It is separate from this infrastructure PR's main-based suite.
The CPPS PR must still run every final-head gate after adopting the shared change.
Physical device/capture/thermal evidence remains #74.

## Capability and failure controls

Before each complete sanitizer suite, an independently compiled Swift control
uses `-O` and the selected sanitizer. The address control provokes a heap use-after-free;
the thread control deliberately permits two worker accesses without synchronization.
Only the expected sanitizer diagnostic and explicit exit code (86/87 respectively)
count as available. ThreadSanitizer may report either its data-race or Swift-access-race
class. A normal exit, unrelated crash or diagnostic, compiler failure, timeout,
or excessive output fails the lane. The deliberate faults never execute in runtime
products or the ordinary test process.

Both optimized controls detected their intended faults on this host. The runner
bounds compilation at 180 seconds, execution at 30 seconds, and output at 1 MiB per
subprocess; failure cleanup terminates the owned process group. Fresh temporary
binaries prevent stale capability evidence. Reports preserve source/binary SHA-256,
compiler arguments, runtime options, detected diagnostic and environment metadata.
Paths are redacted, and existing CI artifact retention includes both reports/logs.
Probe-only runtime options do not propagate to the actual test process.

Local complete main-based lanes passed all **162 reported cases** each, with zero
failures/errors: address 95.829 seconds and thread 154.521 seconds including preparation
and capability controls. The implementing PR retains final-commit CI results.
Failure-path unit checks cover unexpected exits/diagnostics, timeout, excess output,
and consistency between recorded configuration and complete test commands.
