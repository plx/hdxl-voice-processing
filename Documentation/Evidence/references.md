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
`39aae048904095b4006e22ca92ddda5ae220b6ea9651b6d083240fdab016bc0f`.
The 500 ms silent HNR CC result remains unavailable, with all raw frame values
undefined; reference identity:
`f7988507dff2fe42603351f45971275e6ebb23e4fb2bdde6b82879e450e4d1a6`.

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
took 8.127 s. Reused per-run verification/input setup took 124–130 ms in these trials.
These are small-sample host observations, not budgets or device evidence.

| Workload | Input | External process median / p95 (ms) | Parser median (ms) |
| --- | --- | --- | --- |
| CPPS smoke, components only | 120 ms | 237.458 / 238.811 | 0.794 |
| CPPS intermediate export | 120 ms | 386.423 / 393.613 | 12.409 |
| CPPS catalog | 500 ms | 360.607 / 374.273 | 1.779 |
| HNR AC | 500 ms | 168.422 / 168.981 | 0.670 |
| HNR CC | 500 ms | 168.752 / 172.706 | 0.684 |
| Pulses and perturbation | 500 ms | 175.750 / 175.990 | 0.757 |
| Burg formants | 500 ms | 175.055 / 175.073 | 1.162 |
| Silent HNR CC | 500 ms | 162.771 / 166.416 | 0.725 |

External times include process startup, file read, analysis and output formatting.
Native release fixture JSON decode/contract/hash/axis validation on preloaded data,
with detailed bounded signposts, measured median **4.157 ms**, p95 **4.311 ms** over
ten trials. It names the exact CPPS profile/reference identities above and does not
measure a native CPPS algorithm. Build/test launch is separately recorded. Neither
process has an audited allocation backend here, so allocation counts are unavailable.

`Tools/Reference/benchmark.py` retains all trials, nearest-rank p95, throughput,
hardware, units, profile, frame/hop, precision and timing boundaries. Local evidence
is in `.build/reference-evidence-reviewed`; the dedicated hosted workflow retains its
own complete JSON and original-synthetic reference outputs. #25/#27 will expand the
catalog and #66 will consolidate algorithm-specific evidence and conditioning limits.

Review hardening added exact Praat frame-count boundary checks and fresh-directory
Python execution, plus type-sensitive profile validation that rejects booleans in numeric fields. Regeneration changed runner/reference identities only: all initial
numeric values, raw output hashes and profile hashes remained identical. Floating
numeric comparison now applies tolerance consistently to serialized integral-valued
quantities, while structural counts/indices remain exact.
