# Dependency, reference, and fixture policy

Issue #16 establishes the inventory before reference tools or voice recordings are
added. The project's own license remains owner decision
[#78](https://github.com/plx/hdxl-voice-processing/issues/78), as the issue requires.
A release candidate may report that unresolved decision; actual publication is gated.

## Inventory and package boundaries

`Configuration/provenance.json` distinguishes system tools, development tools,
active dependencies, planned dependencies, and design-only sources. Records contain
source URL, selected version (explicit null for planned work), license evidence,
target/consumer use, and redistribution status. System tools are identified by the
tested Xcode/SDK and Python versions; CI records its actual executing versions.
Standard host utilities are developer environment tools, not bundled dependencies.

The root SwiftPM graph has no external dependencies. Keep benchmark/reference
packages in `Benchmarks/` and `Tools/Reference/`. Do not add them as root plugins,
resources, executable helpers, or implicit runtime downloads. PCM analysis must not
install Python, download models, contact services, request microphone permission,
or activate benchmark allocator interposition.

In #17, select an exact Benchmark release/revision, inspect the effective manifest
selected by Swift 6.4 (including versioned manifests/traits), commit its lockfile,
and inventory every transitive dependency/license. Its compiler requirements must
not change runtime minimums. The verifier compares Swift lockfile identities, source
URLs, versions, and revisions with active inventory records. Every active Swift
dependency requires a resolved pin. Fixture and generator paths
must refer to repository files without symbolic links in any path component. A future runtime
dependency needs a justified issue and deliberate graph/provenance policy update.

## Reference execution and source reuse

Implement published mathematics independently in Swift and compare it with pinned
external Praat development processes. #26 selects the exact Praat 7.0.02 binary/source
and artifact hashes in `Tools/Reference/toolchain.json`. The direct CLI uses pinned
Python 3.14.8 standard library only: no Parselmouth, NumPy, embedded Praat, or Python
package resolution is involved. Its lock, installation/regeneration commands, strict
parsers and per-profile manifests are verified independently of runtime builds. No version is marked selected before
the environment is implemented and tested. Reference generation is an explicit
developer operation, never a runtime dependency or automatic build step.

Document mathematical conventions, units, tolerances, and primary-method citations.
Copying GPL or other third-party implementation code is a separate decision: first
create a scoped issue under the relevant epic, review the exact files/revisions,
licenses, and build implications, record the decision, and preserve required notices.
A wrapper does not relicense its underlying library. Tool licenses do not grant
permission to redistribute their example recordings. IVoice's root MIT license is
verified, but its bundled assets need separate review; its color thresholds are not
normative personal-feedback thresholds for this package.

Retain tool-version, command, input, profile, and output identities with reference
results. Current contract JSON fixtures demonstrate serialization, not CPPS accuracy.
No reference interpreter or GPL reference binary is bundled in runtime distributions.

## Fixture provenance

Every committed fixture artifact needs:

- Stable ID, relative path, and SHA-256 of exact bytes.
- Source/generator URL and exact version or hash. Classify original generated
  versus third-party content; original generators also have a checked path,
version, and source hash.
- Redistribution terms and permission evidence. Original artifacts explicitly
  inherit the pending project license decision; publication remains blocked until
  it is selected. Third-party artifacts need independently granted permission and
  cannot inherit the project license merely by being checked in.
- Human-voice classification and documented consent evidence when applicable.
  Private personal calibration recordings and personal identifiers stay out of
  repository fixtures. Public availability alone does not establish permission.
- Ordered transformations, expected profile identity, and reference-output identity.
  Record trimming, mixing, resampling, filtering, normalization, augmentation,
  random seeds, and input/output hashes where relevant.

#22 provides deterministic synthetic audio; #27 curates licensed corpus fixtures.
The initial #27 corpus pins three PVQD v3 sources with their publisher hashes and
CC BY 4.0 grant, separately records the dataset author's public-use consent evidence,
and retains exact originals plus explicitly marked derivatives in test resources only.
See [VoiceCorpus.md](VoiceCorpus.md). Public methods evidence is the documented
consent basis; the project neither holds nor republishes private consent forms.
Source IDs and required attribution are distinct from participant identifiers;
no demographic or diagnostic spreadsheet labels are imported.
Keep fixtures small and reproducible. Consent evidence must be safe to disclose;
do not commit private forms/contact details. Preserve license-required attribution
and other notices, and review distribution conditions before adding material.

The checker inventories Git-visible non-source/non-Markdown artifacts under
`Fixtures/` directories, plus recognized audio extensions anywhere in the checkout
(including AIFC, AAC, and Opus; see `fixture_paths` for the explicit set). Source generators
(`.py`/`.swift`) are source rather than fixture outputs and have checked hashes when
referenced. This catches ordinary omitted fixture files; it cannot detect private
audio encoded inside arbitrary source. Reviewers still inspect added resources.

No pretrained models are present. Adding one requires a separate weight/code/data
license record, integrity pin, explicit opt-in acquisition, and validation. The
current checker rejects models until that policy is deliberately extended.

## Reproduction and change control

```sh
python3 Tools/verify-provenance.py
python3 -m unittest discover -s Tools/Tests -p 'test_*.py'
python3 Tools/Fixtures/generate-contract-fixtures.py --output .build/contract-candidates
cmp .build/contract-candidates/profile-v1.json Tests/HDXLVoiceProcessingTests/Fixtures/profile-v1.json
cmp .build/contract-candidates/result-v1.json Tests/HDXLVoiceProcessingTests/Fixtures/result-v1.json
bash Tools/verify.sh
```

The generator requires an explicit output directory; it neither updates the manifest
nor approves replacing goldens. Artifact hashes include the final LF; canonical
profile identity excludes it. Review changed outputs with their reason, numerical
diffs/tolerances, source/profile changes, and new identities. Never regenerate a
baseline solely to turn a failing test green.

Dependency/reference/generator/profile changes rerun affected synthetic and golden
comparisons, chunk/platform equivalence, compatibility checks, and benchmark workloads.
Keep old/new identities and explain out-of-tolerance differences. Update manifest and
notices in the same issue/PR. Release evidence must identify exact artifacts and
limitations, not floating `latest` versions.

After building the independent consumer, `bash Tools/verify-offline.sh` executes it
under a macOS sandbox denying all network access. `verify.sh` includes this check.
Build/resolve is a separate developer action. This verifies the available contract
and serialization path now; add actual analysis workloads as algorithms arrive.

For actual publication, run `python3 Tools/verify-provenance.py --for-publication`.
Project license files and required dependency notices must be Git-visible repository
files; ignored local files cannot satisfy the gate. It intentionally fails while
#78 is pending. Release dry runs may report that gate
as pending without publishing; actual publication must not bypass it. The checker
verifies recorded metadata/hashes, not legal compatibility.

## Removal and replacement

If material proves unsuitable, stop using/redistributing it and file a scoped removal
issue under its epic. Remove the artifact and references, invalidate affected golden
or calibration identities, and replace it only with documented permitted material.
Check release archives, CI artifacts, caches, and example bundles as well as the tree.
Record IDs/reasons without copying questionable content into issues. Coordinate any
history cleanup with the owner: removing a current file does not erase prior copies.
Then rerun affected correctness/performance checks and update inventory/notices.
