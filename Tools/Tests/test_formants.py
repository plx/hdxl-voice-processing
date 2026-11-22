import copy
import hashlib
import itertools
import json
import struct
import sys
import unittest
from unittest.mock import patch
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Formants.benchmark import BOUNDARIES, throughput, validate_cases
import benchmark as framework
from Formants.reference import DIRECTORY, ROOT, parse, read_cases


class FormantEvidenceTests(unittest.TestCase):
    def test_reference_passes_reject_malformed_or_unmatched_observations(self):
        raw = 'pass\t1\t1\nframe\t1\t0.05\t2\npole\t1\t20\t100\npole\t2\t550\t90\n'
        selected = 'pass\t2\t1\nframe\t1\t0.05\t1\npole\t1\t550\t90\n'
        self.assertEqual(parse(raw + selected, 5000, 10)[0]['selectedHz'], [[550, 90]])
        for text in (
                raw, raw + selected + 'extra', raw + selected.replace('0.05', '0.06'),
                raw + selected.replace('550', '560'), raw + selected.replace('550', '20').replace('90', '100'),
                raw + selected.replace('550', 'NaN'), raw.replace('20\t100', '20\tinf') + selected,
                raw.replace('20\t100', '700\t100') + selected,
                raw.replace('pass\t1\t1', 'pass\t1\t2') + 'frame\t2\t0.05\t0\n' + selected):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse(text, 5000, 10)

    def test_synthetic_inputs_and_corpus_excerpts_match_registered_pcm(self):
        fixtures = [case for file in sorted(DIRECTORY.glob('*.json'))
                    for case in json.loads(file.read_bytes())['cases']]
        licenses = {row['path']: row for row in json.loads((ROOT / 'Configuration/provenance.json').read_bytes())['fixtures']}
        for file in DIRECTORY.glob('*.json'):
            ledger = licenses[str(file.relative_to(ROOT))]
            human = file.stem.startswith('corpus-')
            self.assertEqual(ledger['containsHumanVoice'], human)
            self.assertEqual(ledger['redistribution']['license'], 'CC-BY-4.0' if human else 'project')
            self.assertEqual(ledger['consent']['status'], 'documented' if human else 'not-applicable')
        cases = list(read_cases())
        self.assertEqual(len(cases), 10)
        for (metadata, samples), saved in zip(cases, fixtures, strict=True):
            self.assertEqual(metadata['name'], saved['name'])
            raw = struct.pack(f'<{len(samples)}h', *samples)
            self.assertEqual(hashlib.sha256(raw).hexdigest(), saved['pcm16LESHA256'])
            self.assertEqual(len(samples), saved['sampleCount'])
            self.assertEqual('syntheticPCM16' in metadata, 'corpusPath' not in saved)

    def test_all_matrix_profiles_support_and_hashes_are_validated(self):
        records = []
        for rate, ceiling, order, hop in itertools.product((16000, 44100, 48000), (5000, 5500, 6000),
                                                           (8, 10, 12, 16), (5, 10)):
            profile = dict(schemaVersion=1, sourceSampleRate=rate, ceilingHz=ceiling, order=order, hopMilliseconds=hop,
                           inputPrecision='float64', declaredBandwidthHz=rate // 2, preEmphasisFromHz=50)
            digest = hashlib.sha256(json.dumps(profile, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            records.append(dict(
                profile=profile, name=f'r{rate}-c{ceiling}-o{order}-h{hop}',
                profileIdentity=dict(identifier=dict(name='burg-formants-untracked', version=1), sha256=digest),
                source=dict(epoch=dict(streamID='00000000-0000-0000-0000-000000000046', sequence=0),
                            startSample=0, sampleCount=rate // 10, sampleRate=rate),
                durationSeconds=.1, windowSamples=ceiling // 10,
                expectedFrames=1 + int(((ceiling // 5) * (1 / (2 * ceiling)) - .05) / (hop / 1000))))
        validate_cases(records)
        for key, value in [('expectedFrames', 1), ('durationSeconds', 1), ('profileIdentity', {})]:
            changed = copy.deepcopy(records)
            changed[0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                validate_cases(changed)
        for incomplete in [records[1:], records + records[:1]]:
            with self.assertRaises(ValueError):
                validate_cases(incomplete)

    def test_environment_records_supplied_effective_traits(self):
        flags = ['--traits', 'AllocationDiagnostics,KernelBenchmarks']
        with (patch.object(framework.ci, 'environment', return_value={}),
              patch.object(framework, 'system_state', return_value={'thermalState': 'nominal'}),
              patch.object(framework.ci, 'capture', return_value='test-host'),
              patch.object(framework, 'swift_arguments', side_effect=AssertionError('flags were recomputed'))):
            evidence = framework.measurement_environment('allocation', swift_pm_arguments=flags)
        self.assertEqual(evidence['swiftPMArguments'], flags)

    def test_each_throughput_names_its_work_and_duration(self):
        item = dict(expectedFrames=11, durationSeconds=.1, source=dict(sampleCount=4800))
        expected = dict(Analyze=('frames', 11, .1), Burg=('frames', 1, .05), Resample=('source samples', 4800, .1),
                        Roots=('polynomials', 1, 0), CloseRoots=('polynomials', 1, 0), BoundedExit=('polynomials', 1, 0))
        self.assertEqual(set(expected), set(BOUNDARIES))
        for op, (unit, count, seconds) in expected.items():
            row = throughput(op, item, dict(p50=100, p99=200))
            self.assertEqual((row['unit'], row['itemsPerTrial'], row['sourceSeconds']), (unit, count, seconds))
            self.assertEqual(row['itemsPerSecondAtP99Latency'], count * 5_000_000)
