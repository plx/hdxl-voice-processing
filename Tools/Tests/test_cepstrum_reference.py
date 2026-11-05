"""Offline corruption checks for independent cepstral fixtures and export parsers."""
import copy
import importlib.util
import json
import math
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HERE = ROOT / 'Tools/Cepstrum'
sys.path.insert(0, str(HERE))
SPEC = importlib.util.spec_from_file_location('cepstrum_verify', HERE / 'verify.py')
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)
reference = sys.modules['reference']


class CepstrumReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='cepstrum-corruption-')
        cls.directory = Path(cls.temporary.name) / 'candidate'
        shutil.copytree(verifier.GOLDEN, cls.directory)
        cls.manifest_bytes = (cls.directory / 'manifest.json').read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def changed_record(self, mutation, name='grid-1000'):
        path = self.directory / (name + '.json')
        original = path.read_bytes()
        manifest_path = self.directory / 'manifest.json'
        try:
            record = json.loads(original)
            mutation(record)
            path.write_text(json.dumps(record, allow_nan=False))
            manifest = json.loads(self.manifest_bytes)
            for item in manifest['cases']:
                if item['name'] == name: item['sha256'] = reference.sha(path.read_bytes())
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaises(ValueError): verifier.verify(self.directory)
        finally:
            path.write_bytes(original)
            manifest_path.write_bytes(self.manifest_bytes)

    def test_committed_fixture_identity_and_all_stages(self):
        self.assertEqual(verifier.verify(), {'cases': 41, 'frames': 197,
            'deepMinimumFrames': 60, 'undefinedCepstralBins': 7182})

    def test_modified_recipe_axes_and_stage_units_are_rejected_after_rehash(self):
        self.changed_record(lambda r: r['case'].update(hopSeconds=.01))
        self.changed_record(lambda r: r['axes'].update(quefrencyStepSeconds=.001))
        self.changed_record(lambda r: r['stages']['powerCepstrum'].update(yUnit='decibelsRatio'))
        self.changed_record(lambda r: r.update(schemaVersion=True))

    def test_floors_squares_statuses_and_route_agreement_are_rejected_after_rehash(self):
        self.changed_record(lambda r: r['frames'][0]['powerSpectrum'].__setitem__(1, 12.0))
        self.changed_record(lambda r: r['frames'][0]['logPowerSpectrum'].__setitem__(0, 0.0))
        self.changed_record(lambda r: r['frames'][0]['powerCepstrum'].__setitem__(1, 12.0))
        self.changed_record(lambda r: r['frames'][0]['intervalPowerCepstrum'].__setitem__(1, 1e20))
        self.changed_record(lambda r: r['frames'][0]['signedCepstrum'].__setitem__(0, 0.0), 'synthetic-silence')

    def test_fused_grid_input_hash_and_conditioning_class_are_checked(self):
        self.changed_record(lambda r: r['frames'][0].update(firstResampledIndex=5))
        self.changed_record(lambda r: r['input'].update(normalizedFloat64LESHA256='0' * 64))
        self.changed_record(lambda r: r['input'].update(peakMagnitude=123.0))
        self.changed_record(lambda r: r['frames'][0].update(comparisonClass='deepMinimum'))

    def test_manifest_cannot_hide_missing_extra_or_unapproved_cases(self):
        path = self.directory / 'manifest.json'
        try:
            for change in (lambda m: m.update(calibrationOnly=True), lambda m: m['cases'].pop(),
                           lambda m: m['cases'][0].update(path='../escape.json'),
                           lambda m: m.update(generatorSHA256='0' * 64),
                           lambda m: m.update(schemaVersion=True)):
                manifest = json.loads(self.manifest_bytes); change(manifest)
                path.write_text(json.dumps(manifest))
                with self.assertRaises(ValueError): verifier.verify(self.directory)
        finally: path.write_bytes(self.manifest_bytes)
        extra = self.directory / 'unregistered.json'
        try:
            extra.write_text('{}')
            with self.assertRaises(ValueError): verifier.verify(self.directory)
        finally: extra.unlink()

    def test_regeneration_rejects_committed_or_external_destinations_before_tool_execution(self):
        for destination in (verifier.GOLDEN, Path(self.temporary.name) / 'outside-build'):
            with self.assertRaisesRegex(ValueError, 'below .build'):
                reference.generate(destination)

    def test_intermediate_parser_rejects_nonfinite_duplicate_or_inconsistent_values(self):
        raw = '\n'.join(('begin\tcepstral-frame-v2\t2', 'windowed\t0\t0.1', 'windowed\t1\t-0.1',
            'bins\t2', f'spectrum\t0\t0\t0\t0\t{math.log(1e-300)}',
            f'spectrum\t1\t0.2\t0\t0.08000000000000002\t{math.log(0.08000000000000002)}',
            'cepstrum\t0\t1\t1', 'cepstrum\t1\t-2\t4', 'end\tcepstral-frame-v2'))
        self.assertEqual(reference.parse_frame(raw, 2, 2)['signedCepstrum'], [1, -2])
        for bad in (raw.replace('windowed\t1', 'windowed\t0'), raw.replace('0.1\n', 'nan\n'),
                    raw.replace('cepstrum\t1\t-2\t4', 'cepstrum\t1\t-2\t5'),
                    raw.replace('spectrum\t1\t0.2\t0', 'spectrum\t1\t0.2\t1'),
                    raw.replace('end\tcepstral-frame-v2', ''), raw + '\nextra'):
            with self.assertRaises(ValueError): reference.parse_frame(bad, 2, 2)

    def test_undefined_interval_bins_cannot_be_replaced_with_zero(self):
        result = reference.compare_routes([None, None], [0.0, None])
        self.assertEqual(result['availabilityDisagreements'], 1)
        self.assertEqual(result['finiteBins'], 0)
        self.assertNotEqual(result['availabilityDisagreements'], reference.compare_routes([None], [None])['availabilityDisagreements'])


if __name__ == '__main__': unittest.main()
