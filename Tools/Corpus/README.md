# Voice corpus development tools

See [the corpus guide](../../Documentation/VoiceCorpus.md) for exact source terms,
task annotations, modifications, negative cases and stable workload definitions.

```sh
python3 Tools/Corpus/corpus.py verify
python3 Tools/Corpus/corpus.py generate --output .build/corpus-candidates
python3 Tools/Corpus/corpus.py prepare-long-stream --output .build/corpus-long
python3 Tools/Corpus/benchmark.py --output .build/corpus-evidence
```

Only the explicit `acquire --output NEW_DIRECTORY` command downloads the three pinned
public originals. All other commands use committed assets offline. Candidate generation
does not change expected results or the provenance inventory. Review identities,
permission, transformations and coverage before deliberately replacing a fixture.

`corpus_catalog.py` owns the fixed source selection and original engineering recipes;
`corpus.py` uses Python 3.14.8's standard library for strict RIFF decoding, bounded
integer transforms, manifests and verification. The Swift test-only decoder is
independent and has no runtime-product dependency. `benchmark.py` measures native
file loading/decoding separately, checks every output, and retains complete metadata.

Downstream DSP must receive decoded PCM and declared source support. The prepared
long stream's two-second joins are explicit discontinuities; they cannot be used
to claim uninterrupted natural speech or physical-device feasibility.
