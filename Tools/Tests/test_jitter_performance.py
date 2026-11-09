"""Performance evidence must prove input/membership and actual measured coverage."""
import copy
import json
import math
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tools/Jitter'))
import performance_oracle as oracle
import performance_receipts as receipts


def period_receipt(kind='periods',dense=False):
    name,row=next((name,row) for name,row in receipts.expected_cases().items()
                  if row['kind']==kind and row['denseRejections']==dense)
    profile=receipts.expected_profile(row); rate=row['sampleRate']
    periods=oracle.generated_periods(row)
    n=row['durationMilliseconds']*row['frequencyHz']//1000
    frame=row['durationMilliseconds']*rate//1000
    clock=math.ceil(periods[-1]['endSeconds']*rate)+1 if kind=='rolling' else frame
    start=clock-frame if kind=='rolling' else 0
    query=dict(startSeconds=start/rate,endSeconds=clock/rate)
    expected=oracle.evaluate(periods,profile,query)
    selected=sum(expected['selected'])
    count=selected+int(selected<len(periods)) if kind=='rolling' else len(periods)
    coverage=dict(expected['coverage'],inputPeriodCount=count,analyzedDurationSeconds=frame/rate)
    identity=receipts.identity(profile['definition']+'-'+profile['applicability'],profile)
    report=dict(schemaVersion=1,profile=identity,applicability=profile['applicability'],
        query=query,coverage=coverage,inputProvenance=dict(kind='suppliedPeriods'),
        dependencyTiming=dict(source=receipts.interval(0,clock,rate),includedSampleCount=clock,effectiveDelaySeconds=0))
    for variant,value in expected['values'].items():
        assert value is not None
        report[variant]=dict(variant=variant,status='available',value=value,
            unit='seconds' if variant=='absolute' else 'fraction')
    capacity=n+2; base=1<<(capacity-1).bit_length()
    prepared=capacity*16 if kind=='periods' else capacity*88+2*base*352
    record=dict(name=name,workload=row,configuration=profile,profileIdentity=identity,
        operations=receipts.OPERATIONS[kind],inputPeriodCount=len(periods),
        measuredPeriodUpdates=n if kind=='rolling' else 0,frameSampleCount=frame,
        hopDefinition='oneCompletePeriodVariableSourceHop' if kind=='rolling' else 'wholeDeclaredInterval',
        preparedCombinedBufferBytes=prepared,preparedSeparateBufferBytes=5*prepared,
        preparedInputBytes=len(periods)*192,periodInputSHA256=oracle.period_hash(periods),result=report,
        checksums={op:1. for op in receipts.OPERATIONS[kind] if op!='Prepare'})
    if kind=='rolling':
        record.update(windowSampleCount=frame,sumTreeNodeUpdates=len(periods)*10,
            observedAppendCount=len(periods),observedQueryCount=n)
        report['sampleAlignedQuery']=receipts.interval(start,frame,rate)
    return record


def check_one(record):
    with patch.object(receipts,'expected_cases',return_value={record['name']:record['workload']}):
        return receipts.validate_matrix([record])


def raw_capture(matrix,mode):
    rows=[]
    metrics=['wallClock','cpuTotal'] if mode=='timing' else ['wallClock',*receipts.DIAGNOSTICS]
    for name in sorted(receipts.benchmark_names(matrix,mode)):
        allocating=name==receipts.CONTROL or '.Prepare.' in name
        rows.extend([dict(name=name,target='JitterBenchmarks'),[
            dict(metric={m:{}},scalingFactor=1,statistics=dict(histogram={
                '_totalCount':30,'maxValue':int(allocating or m in ('wallClock','cpuTotal')),'counts':[30]}))
            for m in metrics]])
    return dict(results=rows)


def pcm_receipt():
    row=next(r for r in receipts.expected_cases().values() if r['kind']=='pcm')
    stem=f"gaussian-{row['sampleRate']}-{row['frequencyHz']}-{row['precision']}"
    path=ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/Pulses'/(stem+'.json')
    data=path.read_bytes();fixture=json.loads(data);wave=path.with_suffix('.wav').read_bytes()
    ref=fixture['reference'];pitch=ref['pitch'];count=fixture['case']['sampleCount'];rate=row['sampleRate']
    points=ref['data']['pulseTimesSeconds'];frames=len(pitch['frequenciesHz']);capacity=4096+frames
    # These are declared test inputs from external point locations, not native
    # jitter goldens or an independent assertion about pulse reliability flags.
    periods=[dict(startSeconds=a,endSeconds=b,runID=0,rejections=dict(rawValue=0))
             for a,b in zip(points,points[1:])]
    pulse_profile=receipts.expected_pulse_profile(row,fixture)
    pulse_bytes=count*8+capacity*224+4096*120+(math.ceil(.45*rate/20)+7)*32
    contour=dict(schemaVersion=1,sampleRate=rate,sampleCount=count,
        firstCenterSeconds=pitch['firstCenterSeconds'],stepSeconds=pitch['stepSeconds'],
        ceilingHz=pitch['ceilingHz'],frequenciesHz=pitch['frequenciesHz'])
    pcm=dict(fixture=stem,fixtureSHA256=receipts.digest(data),encodedInputSHA256=receipts.digest(wave),
        normalizedInputSHA256=receipts.digest(wave[56:]),sampleCount=count,f0FrameCount=frames,
        f0FirstCenterSeconds=pitch['firstCenterSeconds'],f0StepSeconds=pitch['stepSeconds'],
        preparedContourBytes=frames*8,pulseConfiguration=pulse_profile,
        pulseProfile=receipts.identity(pulse_profile['definition']+'-completeInterval',pulse_profile),
        contourIdentity=receipts.identity('hdxl-pulse-supplied-f0',contour),
        rawPulseTimesSeconds=points,mappedPeriods=periods,maximumReferenceErrorSamples=0.,
        preparedPulseBufferBytes=pulse_bytes,preparedStatisticsBufferBytes=capacity*16)
    return dict(pcm=pcm,preparedCombinedBufferBytes=pulse_bytes+capacity*48,
        preparedSeparateBufferBytes=0,preparedInputBytes=count*4+len(periods)*32),row


class JitterPerformanceTests(unittest.TestCase):
    def test_matrix_covers_every_required_duration_frequency_rejection_and_precision(self):
        rows=receipts.expected_cases()
        self.assertEqual(len(rows),68)
        groups=[set(receipts.expected_cases(s)) for s in receipts.SHARDS]
        self.assertEqual([len(g) for g in groups],[16,16,16,16,4])
        self.assertEqual(set.union(*groups),set(rows))
        self.assertEqual(sum(map(len,groups)),len(rows))
        self.assertEqual({r['frequencyHz'] for r in rows.values()},{80,600})
        for kind in ('periods','rolling'):
            selected=[r for r in rows.values() if r['kind']==kind]
            self.assertEqual({(r['durationMilliseconds'],r['frequencyHz'],r['denseRejections'],r['precision']) for r in selected},
                {(d,hz,dense,p) for d in (250,1000,3000,10000) for hz in (80,600)
                 for dense in (False,True) for p in ('float32','float64')})
        with self.assertRaises(ValueError): receipts.expected_cases('not-a-shard')

    def test_independent_equations_have_closed_form_anchors_and_no_survivor_stitching(self):
        for dense in (False,True):
            record=period_receipt(dense=dense)
            result=record['result']
            for variant,value in dict(local=.02,absolute=.00025,rap=.04/3,ppq5=.008,ddp=.04).items():
                self.assertAlmostEqual(result[variant]['value'],value,places=13)
            c=result['coverage']
            self.assertEqual([c[k] for k in ('acceptedPeriodCount','acceptedPairCount',
                'acceptedRAPNeighborhoodCount','acceptedPPQ5NeighborhoodCount')],
                [12,10,8,4] if dense else [20,19,18,16])
            self.assertEqual(c['rejections']['discontinuousPairs'],9 if dense else 0)
            check_one(record)

    def test_rehashed_wrong_values_counts_units_or_profile_cannot_become_expectations(self):
        for kind in ('periods','rolling'):
            good=period_receipt(kind,True); check_one(good)
            mutations=[
                lambda r:r['configuration'].__setitem__('maximumAdjacentPeriodFactor',2),
                lambda r:r['profileIdentity'].__setitem__('sha256','0'*64),
                lambda r:r.__setitem__('periodInputSHA256','0'*64),
                lambda r:r.__setitem__('inputPeriodCount',0),
                lambda r:r.__setitem__('preparedCombinedBufferBytes',0),
                lambda r:r.__setitem__('preparedSeparateBufferBytes',1),
                lambda r:r.__setitem__('preparedInputBytes',1),
                lambda r:r.__setitem__('frameSampleCount',1),
                lambda r:r.__setitem__('hopDefinition','none'),
                lambda r:r['result']['local'].__setitem__('value',.9),
                lambda r:r['result']['absolute'].__setitem__('unit','fraction'),
                lambda r:r['result']['rap'].__setitem__('status','unavailable'),
                lambda r:r['result']['coverage'].__setitem__('acceptedPairCount',0),
                lambda r:r['result']['coverage']['rejections'].__setitem__('excluded',0),
                lambda r:r['result']['coverage'].__setitem__('acceptedPeriodDurationSeconds',0),
                lambda r:r['result']['dependencyTiming'].__setitem__('includedSampleCount',0),
                lambda r:r['result']['query'].__setitem__('startSeconds',.125),
                lambda r:r['checksums'].pop('Combined'),
                lambda r:r['checksums'].__setitem__('Combined',0),
            ]
            for mutate in mutations:
                bad=copy.deepcopy(good); mutate(bad)
                with self.assertRaises(ValueError): check_one(bad)

    def test_rolling_receipts_require_real_incremental_work_and_exact_window_identity(self):
        good=period_receipt('rolling'); check_one(good)
        for mutate in [
            lambda r:r.__setitem__('observedAppendCount',1),
            lambda r:r.__setitem__('observedQueryCount',1),
            lambda r:r.__setitem__('measuredPeriodUpdates',0),
            lambda r:r.__setitem__('sumTreeNodeUpdates',0),
            lambda r:r.__setitem__('sumTreeNodeUpdates',10**9),
            lambda r:r['result']['sampleAlignedQuery'].__setitem__('startSample',0),
            lambda r:r.__setitem__('windowSampleCount',1),
        ]:
            bad=copy.deepcopy(good); mutate(bad)
            with self.assertRaises(ValueError): check_one(bad)

    def test_incomplete_duplicate_or_extra_matrix_rows_fail(self):
        row=period_receipt()
        with self.assertRaises(ValueError): receipts.validate_matrix([])
        with self.assertRaises(ValueError): receipts.validate_matrix([row])
        with patch.object(receipts,'expected_cases',return_value={row['name']:row['workload']}):
            with self.assertRaises(ValueError): receipts.validate_matrix([row,row])
            bad=copy.deepcopy(row);bad['name']='invented'
            with self.assertRaises(ValueError): receipts.validate_matrix([bad])

    def test_oracle_rejects_invalid_observations_instead_of_producing_zero(self):
        row=period_receipt();profile=row['configuration'];query=row['result']['query']
        original=oracle.generated_periods(row['workload'])
        mutations=[lambda p:p[0].__setitem__('endSeconds',p[0]['startSeconds']),
            lambda p:p[1].__setitem__('startSeconds',-1),
            lambda p:p[0].__setitem__('runID',True),
            lambda p:p[0].__setitem__('endSeconds',float('nan')),
            lambda p:p[0].__setitem__('endSeconds',10**1000),
            lambda p:p[0]['rejections'].__setitem__('rawValue',64)]
        for mutate in mutations:
            bad=copy.deepcopy(original);mutate(bad)
            with self.assertRaises(ValueError): oracle.evaluate(bad,profile,query)

    def test_distribution_controls_and_steady_state_allocations_fail_closed(self):
        matrix=[period_receipt('rolling'),dict(name='pcm-fixture',operations=receipts.OPERATIONS['pcm'])]
        for mode in ('timing','allocation'):
            receipts.validate_raw(raw_capture(matrix,mode),matrix,mode)
        for metric in receipts.DIAGNOSTICS:
            bad=raw_capture(matrix,'allocation')
            control_index=next(i for i in range(0,len(bad['results']),2) if bad['results'][i]['name']==receipts.CONTROL)
            for m in bad['results'][control_index+1]:
                if metric in m['metric']:m['statistics']['histogram']['maxValue']=0
            with self.assertRaisesRegex(ValueError,'Unavailable'):receipts.validate_raw(bad,matrix,'allocation')
        for metric in receipts.ALLOCATIONS:
            for operation in ('Combined','Separate','QueryOnly','PulseOnly','PCMCombined','StatisticsOnly'):
                bad=raw_capture(matrix,'allocation')
                index=next(i for i in range(0,len(bad['results']),2) if f'.{operation}.' in bad['results'][i]['name'])
                for m in bad['results'][index+1]:
                    if metric in m['metric']:m['statistics']['histogram']['maxValue']=1
                with self.assertRaisesRegex(ValueError,'Steady-state'):receipts.validate_raw(bad,matrix,'allocation')

    def test_pcm_receipts_retain_exact_source_f0_periods_and_memory_geometry(self):
        good,row=pcm_receipt();profile=receipts.expected_profile(row)
        receipts.validate_pcm(good,row,profile)
        mutations=[
            lambda r:r['pcm'].__setitem__('fixture','wrong'),
            lambda r:r['pcm'].__setitem__('fixtureSHA256','0'*64),
            lambda r:r['pcm'].__setitem__('encodedInputSHA256','0'*64),
            lambda r:r['pcm'].__setitem__('normalizedInputSHA256','0'*64),
            lambda r:r['pcm'].__setitem__('f0FrameCount',0),
            lambda r:r['pcm'].__setitem__('f0StepSeconds',.01),
            lambda r:r['pcm']['contourIdentity'].__setitem__('sha256','0'*64),
            lambda r:r['pcm']['pulseProfile'].__setitem__('sha256','0'*64),
            lambda r:r['pcm']['pulseConfiguration'].__setitem__('maximumAdjacentPeriodFactor',2),
            lambda r:r['pcm']['rawPulseTimesSeconds'].__setitem__(0,.2),
            lambda r:r['pcm']['mappedPeriods'].pop(),
            lambda r:r['pcm']['mappedPeriods'][0].__setitem__('startSeconds',.1),
            lambda r:r['pcm'].__setitem__('maximumReferenceErrorSamples',1),
            lambda r:r['pcm'].__setitem__('preparedPulseBufferBytes',0),
            lambda r:r['pcm'].__setitem__('preparedStatisticsBufferBytes',0),
            lambda r:r.__setitem__('preparedCombinedBufferBytes',0),
            lambda r:r.__setitem__('preparedInputBytes',0),
        ]
        for mutate in mutations:
            bad=copy.deepcopy(good);mutate(bad)
            with self.assertRaises(ValueError):receipts.validate_pcm(bad,row,profile)

    def test_missing_samples_metrics_target_scaling_and_units_are_rejected(self):
        matrix=[period_receipt()]
        mutations=[lambda r:r['results'].pop(),lambda r:r['results'].__setitem__(2,r['results'][0]),
            lambda r:r['results'][0].__setitem__('target','Wrong'),lambda r:r['results'][1].pop(),
            lambda r:r['results'][1][0].__setitem__('scalingFactor',100),
            lambda r:r['results'][1][0]['statistics']['histogram'].__setitem__('_totalCount',29),
            lambda r:r['results'][1][0]['statistics']['histogram'].__setitem__('counts',[-1,31]),
            lambda r:r['results'][1][0]['statistics']['histogram'].__setitem__('maxValue',0)]
        for mutate in mutations:
            bad=raw_capture(matrix,'timing');mutate(bad)
            with self.assertRaises(ValueError):receipts.validate_raw(bad,matrix,'timing')
        good=[dict(name='case - '+m,value=1,unit='ns') for m in ('Time (wall clock)','Time (total CPU)')]
        receipts.validate_export(good,['case'],'timing')
        for bad in (good[:1],good+good,[{**good[0],'unit':'ms'},good[1]],
                    [{**good[0],'value':float('nan')},good[1]]):
            with self.assertRaises(ValueError):receipts.validate_export(bad,['case'],'timing')

    def test_costs_separate_whole_update_batches_and_query_only_operations(self):
        row=period_receipt('rolling')
        values={f"Jitter.{op}.{row['name']} - Time (wall clock)":cost for op,cost in
                [('Prepare',10000),('Combined',20000),('Separate',60000),('QueryOnly',100)]}
        costs=receipts.operation_costs([row],values)[row['name']]
        self.assertEqual(costs['separateToCombinedRatio'],3)
        self.assertEqual(costs['amortizedNanosecondsPerUpdateAndQuery'],1000)
        self.assertEqual(costs['queryOnlyNanoseconds'],100)
        values[f"Jitter.Combined.{row['name']} - Time (wall clock)"]=0
        with self.assertRaises(ValueError):receipts.operation_costs([row],values)


if __name__=='__main__':unittest.main()
