"""Stage receipts must cover every attempted match, with explicit acceptance groups."""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('pulse_stage_benchmark', ROOT/'Tools/Pulses/stage_benchmark.py')
stages = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(stages)


def example():
    receipt = dict(workload=dict(fixture='example',precision='float64',support='completeInterval'),
        configuration=dict(pitchFloorHz=20,pitchCeilingHz=700),profileIdentity={'id':'profile'},
        f0ContourIdentity={'id':'f0'},inputSampleCount=8000,inputDurationSeconds=.5,
        encodedInputSHA256='a'*64,fixtureJSONSHA256='b'*64,
        counts=dict(attempts=2,acceptedAttempts=1,rejectedAttempts=1,eligibleAttempts=1))
    case = {k:receipt[k] for k in ('configuration','profileIdentity','f0ContourIdentity','inputSampleCount','encodedInputSHA256','fixtureJSONSHA256')}
    case.update(name='example-float64', attempts=[
        dict(index=0,acceptedByReferenceGates=True,eligible=True,interpolationExpected=True,
             rejectionBits=0,fromSeconds=.25,frequencyHz=150,direction='backward'),
        dict(index=1,acceptedByReferenceGates=False,eligible=False,interpolationExpected=False,
             rejectionBits=1<<14,fromSeconds=.25,frequencyHz=150,direction='forward')], trials=[])
    for index in range(5):
        for mode in ('disabled','detailed'):
            case['trials'].append(dict(index=index,mode=mode,replayNanoseconds=1000,checksum=1.5,
                matchingNanoseconds=[100,200] if mode=='detailed' else [None,None],
                interpolationNanoseconds=[10,None] if mode=='detailed' else [None,None]))
    return dict(schemaVersion=1,definition='pulse-actual-attempt-kernel-replay-v1',
        limitations='Includes overhead; production sampling unchanged; not full analyzer throughput',cases=[case]), [receipt]


class PulseStageBenchmarkTests(unittest.TestCase):
    def test_complete_paired_attempts_remain_separate_from_stage_absence(self):
        report,matrix=example(); result=stages.validate(report,matrix)['example-float64']
        self.assertEqual(result['attempts'],2)
        self.assertEqual(result['interpolationSkipped'],1)
        self.assertEqual(result['stages']['accepted.matching']['sampleCount'],5)
        self.assertEqual(result['stages']['rejected.matching']['median'],200)
        self.assertEqual(result['stages']['rejected.interpolation']['sampleCount'],0)
        self.assertIsNone(result['stages']['rejected.interpolation']['p99'])
        report['cases'][0]['trials'][1]['interpolationNanoseconds'][0] = 0
        self.assertEqual(stages.validate(report,matrix)['example-float64']['stages']['accepted.interpolation']['minimum'],0)

    def test_missing_changed_or_duplicated_coverage_fails(self):
        good,matrix=example()
        mutations=[lambda r:r['cases'].pop(),lambda r:r['cases'].append(r['cases'][0]),
            lambda r:r.__setitem__('schemaVersion',True),lambda r:r.__setitem__('limitations','timing'),
            lambda r:r['cases'][0].__setitem__('encodedInputSHA256','c'*64),
            lambda r:r['cases'][0]['attempts'].pop(),
            lambda r:r['cases'][0]['attempts'][0].__setitem__('index',1),
            lambda r:r['cases'][0]['attempts'][0].__setitem__('eligible',False),
            lambda r:r['cases'][0]['attempts'][1].__setitem__('acceptedByReferenceGates',True),
            lambda r:r['cases'][0]['attempts'][0].__setitem__('direction','seed'),
            lambda r:r['cases'][0]['attempts'][0].__setitem__('frequencyHz',0),
            lambda r:r['cases'][0]['attempts'][0].__setitem__('fromSeconds',1),
            lambda r:r['cases'][0]['trials'].pop(),
            lambda r:r['cases'][0]['trials'].append(r['cases'][0]['trials'][0])]
        for mutate in mutations:
            bad=copy.deepcopy(good);mutate(bad)
            with self.assertRaises(ValueError):stages.validate(bad,matrix)

    def test_instrumentation_changes_invalid_clocks_and_prefix_sampling_fail(self):
        good,matrix=example()
        mutations=[lambda r:r['cases'][0]['trials'][0].__setitem__('checksum',2),
            lambda r:r['cases'][0]['trials'][0].__setitem__('replayNanoseconds',0),
            lambda r:r['cases'][0]['trials'][1].__setitem__('replayNanoseconds',1),
            lambda r:r['cases'][0]['trials'][0].__setitem__('matchingNanoseconds',[100,None]),
            lambda r:r['cases'][0]['trials'][1].__setitem__('matchingNanoseconds',[100]),
            lambda r:r['cases'][0]['trials'][1].__setitem__('matchingNanoseconds',[100,None]),
            lambda r:r['cases'][0]['trials'][1].__setitem__('interpolationNanoseconds',[10,0]),
            lambda r:r['cases'][0]['trials'][1].__setitem__('interpolationNanoseconds',[False,None])]
        for mutate in mutations:
            bad=copy.deepcopy(good);mutate(bad)
            with self.assertRaises(ValueError):stages.validate(bad,matrix)


if __name__=='__main__':unittest.main()
