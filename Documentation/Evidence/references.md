# Initial independent-reference evidence

Issue #26, recorded 2026-11-04. This establishes independent reference infrastructure
and initial fixtures; native CPPS/HNR/pulse/formant implementations remain in their
algorithm leaves. Recipe/historical differences are tracked in #86; physical evidence
remains deferred in #74.

## Identity and reproducibility

Praat 7.0.02, source `6f3da9ef1d8cce0d5684afc104d02888dfc71b25`, official macOS
artifact SHA-256 `9e4d1d220cff32ccfa4521114d23c11ebbfd792db61884f6019a44bd4aba19d4`;
executable SHA-256 `8af6acef5b539d69e5decc07a016882a3f04f7a545715756dd9a5e5c7fdf599a`.
The complete lock, commands and protocol are in `Tools/Reference/README.md`.

The initial 120 ms 200 Hz saw CPPS is **31.643434394886956 dB**, from 11 frames,
100 ms physical Gaussian support, 2 ms hop, 10 kHz analysis rate, and two 513×11
raw/smoothed power-cepstrum matrices. The profile hash is
`3dc8164b59c24a1f45a68317f4d894f06d94066d50770adadc12fc6dd33c29f3`.
Reference identity:
`d5f6921e52c89073ee996279c94892239290ada28b6a4f3390de96c8294bec5b`.
The 500 ms silent HNR CC result remains unavailable, with all raw frame values
undefined; reference identity:
`5ec7f00bcfeb2ce83985f93e3ba2efeb362423bfe6e92092e69dc4361f3448ef`.

Both committed outputs were generated twice during construction, then independently
regenerated three more times using the installed hash-verified binary. All complete
manifests/components matched. Eight workloads × three trials also covered HNR AC/CC,
11 perturbation scalars with pulse times, and Burg formant frequency/bandwidth frames.
Six N=8 DFT/energy goldens are hand-derived; Swift direct equations independently
check their signs/scaling and energies. Original inputs contain no human recording.

Offline negative tests reject altered input/profile identities, wrong rate/sample
axes, incomplete/duplicate records, wrong fraction/percent units, nonfinite and
locale-dependent numeric strings, malformed PCM and reference failure. They preserve
unavailable, unsupported input, disagreement and numeric zero as separate outcomes.
The full debug lane also passes consumer graph/link and network-denied execution.

## Local performance boundary

Host: Mac13,1 arm64, macOS 27.0.1; Python 3.14.8, Swift 6.4.0.34.1, Xcode 27.0.
Clean acquisition (download, checksum, read-only mount/copy/detach and binary verify)
took 8.127 s. Reused per-run verification/input setup took 123–127 ms in these trials.
These are small-sample host observations, not budgets or device evidence.

| Workload | Input | External process median / p95 (ms) | Parser median (ms) |
| --- | --- | --- | --- |
| CPPS smoke, components only | 120 ms | 230.364 / 233.365 | 0.733 |
| CPPS intermediate export | 120 ms | 379.513 / 383.088 | 12.476 |
| CPPS catalog | 500 ms | 362.432 / 365.102 | 1.872 |
| HNR AC | 500 ms | 166.940 / 170.430 | 0.783 |
| HNR CC | 500 ms | 171.139 / 171.444 | 0.721 |
| Pulses and perturbation | 500 ms | 168.466 / 174.605 | 0.730 |
| Burg formants | 500 ms | 178.530 / 178.899 | 1.128 |
| Silent HNR CC | 500 ms | 169.598 / 172.046 | 0.821 |

External times include process startup, file read, analysis and output formatting.
Native release fixture JSON decode/contract/hash/axis validation on preloaded data,
with detailed bounded signposts, measured median **4.083 ms**, p95 **4.322 ms** over
ten trials. It names the exact CPPS profile/reference identities above and does not
measure a native CPPS algorithm. Build/test launch is separately recorded. Neither
process has an audited allocation backend here, so allocation counts are unavailable.

`Tools/Reference/benchmark.py` retains all trials, nearest-rank p95, throughput,
hardware, units, profile, frame/hop, precision and timing boundaries. Local evidence
is in `.build/reference-evidence-cycle3`; the dedicated hosted workflow retains its
own complete JSON and original-synthetic reference outputs. #25/#27 will expand the
catalog and #66 will consolidate algorithm-specific evidence and conditioning limits.

Review hardening added exact Praat frame-count boundary checks and fresh-directory
Python execution, plus type-sensitive profile validation that rejects booleans in numeric fields. Regeneration changed runner/reference identities only: all initial
numeric values, raw output hashes and profile hashes remained identical. Floating
numeric comparison now applies tolerance consistently to serialized integral-valued
quantities, while structural counts/indices remain exact.

The final preflight also enforces the 30,000-frame CPPS ceiling before launching
Praat. A 61-second input and an oversized matrix export are regression-tested to
return unsupportedRange without verifying or running the external executable.
