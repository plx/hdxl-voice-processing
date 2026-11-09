"""Performance evidence must prove input/membership and actual measured coverage."""
import copy
import json
import math
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Tools/Shimmer'))
import shimmer_performance_oracle as oracle
import shimmer_performance_receipts as receipts


def amplitude_receipt(kind='amplitudes',dense=False):
    name,row=next((name,row) for name,row in receipts.expected_cases().items()
                  if row['kind']==kind and row['denseRejections']==dense)
    profile=receipts.expected_profile(row); rate=row['sampleRate']
    amplitudes=oracle.generated_amplitudes(row)
    n=row['durationMilliseconds']*row['frequencyHz']//1000
    frame=row['durationMilliseconds']*rate//1000
    clock=math.ceil(amplitudes[-1]['timeSeconds']*rate)+1 if kind=='rolling' else frame
    start=clock-frame if kind=='rolling' else 0
    query=dict(startSeconds=start/rate,endSeconds=clock/rate)
    retained=[a for a in amplitudes if start/rate<=a['timeSeconds']<=clock/rate] if kind=='rolling' else amplitudes
    expected=oracle.evaluate(retained,query,profile)
    coverage=dict(expected['coverage'],analyzedDurationSeconds=frame/rate)
    identity=receipts.identity(profile['definition']+'-'+profile['applicability'],profile)
    report=dict(schemaVersion=1,profile=identity,applicability=profile['applicability'],
        query=query,coverage=coverage,inputProvenance=dict(kind='suppliedAmplitudes'),
        dependencyTiming=dict(source=receipts.interval(0,clock,rate),includedSampleCount=clock,effectiveDelaySeconds=0))
    for variant,value in expected['values'].items():
        estimate=dict(variant=variant,status='available' if value is not None else 'unavailable',
            unit='decibelsRatio' if variant=='db' else 'fraction')
        if value is None: estimate['unavailability']='discontinuity'
        else: estimate['value']=3*expected['values']['apq3'] if variant=='dda' else value
        report[variant]=estimate
    capacity=n+2
    prepared=capacity*24 if kind=='amplitudes' else capacity*128
    record=dict(name=name,workload=row,configuration=profile,profileIdentity=identity,
        operations=receipts.OPERATIONS[kind],inputAmplitudeCount=len(amplitudes),
        measuredAmplitudeUpdates=min(64,n) if kind=='rolling' else 0,frameSampleCount=frame,
        hopDefinition='oneAmplitudeVariableSourceHop' if kind=='rolling' else 'wholeDeclaredInterval',
        preparedCombinedBufferBytes=prepared,preparedSeparateBufferBytes=6*prepared,
        preparedInputBytes=len(amplitudes)*208,amplitudeInputSHA256=oracle.amplitude_hash(amplitudes),result=report,
        checksums={op:1. for op in receipts.OPERATIONS[kind] if op!='Prepare'})
    if kind=='rolling':
        record.update(windowSampleCount=frame,evaluatedAmplitudes=n*min(64,n),
            observedAppendCount=len(amplitudes),observedQueryCount=min(64,n))
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
        rows.extend([dict(name=name,target='ShimmerBenchmarks'),[
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
    # Declared test observations use external amplitude values and explicit
    # absent edge support, not goldens captured from a native execution.
    by_index={a['pulseIndex']:a['rmsAmplitude'] for a in ref['data']['amplitudes']}
    amplitudes=[dict(timeSeconds=t,sequenceIndex=i,runID=0,rejections=dict(rawValue=0),
                    **({'amplitude':by_index[i]} if i in by_index else {})) for i,t in enumerate(points)]
    upstream=[0 if i in by_index else 4 for i in range(len(points))]
    case=dict(sampleCount=count,sampleRate=rate,queryStartSeconds=0.,queryEndSeconds=count/rate)
    for i,a in enumerate(amplitudes):
        a['rejections']['rawValue']=receipts.converted_flags(i,amplitudes,upstream,case)
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
        rawPulseTimesSeconds=points,mappedAmplitudes=amplitudes,upstreamAmplitudeRejections=upstream,maximumReferenceErrorSamples=0.,
        preparedPulseBufferBytes=pulse_bytes,preparedStatisticsBufferBytes=capacity*24)
    return dict(pcm=pcm,preparedCombinedBufferBytes=pulse_bytes+capacity*72,
        preparedSeparateBufferBytes=0,preparedInputBytes=count*4+len(amplitudes)*48),row


class ShimmerPerformanceTests(unittest.TestCase):
    def test_matrix_covers_every_required_duration_frequency_rejection_and_precision(self):
        rows=receipts.expected_cases()
        self.assertEqual(len(rows),68)
        groups=[set(receipts.expected_cases(s)) for s in receipts.SHARDS]
        self.assertEqual([len(g) for g in groups],[16,16,16,16,4])
        self.assertEqual(set.union(*groups),set(rows))
        self.assertEqual(sum(map(len,groups)),len(rows))
        self.assertEqual({r['frequencyHz'] for r in rows.values()},{80,600})
        for kind in ('amplitudes','rolling'):
            selected=[r for r in rows.values() if r['kind']==kind]
            self.assertEqual({(r['durationMilliseconds'],r['frequencyHz'],r['denseRejections'],r['precision']) for r in selected},
                {(d,hz,dense,p) for d in (250,1000,3000,10000) for hz in (80,600)
                 for dense in (False,True) for p in ('float32','float64')})
        with self.assertRaises(ValueError): receipts.expected_cases('not-a-shard')

    def test_independent_equations_have_closed_form_anchors_and_no_survivor_stitching(self):
        record=amplitude_receipt()
        result=record['result']; mean=(10*.9+9*1.1)/19
        for variant,value in dict(local=.2/mean,db=20*math.log10(1.1/.9),
                apq3=(.4/3)/mean,apq5=.08/mean,apq11=(1.2/11)/mean,dda=.4/mean).items():
            self.assertAlmostEqual(result[variant]['value'],value,places=13)
        self.assertEqual([result['coverage'][k] for k in ('acceptedAmplitudeCount','acceptedPairCount',
            'acceptedAPQ3NeighborhoodCount','acceptedAPQ5NeighborhoodCount','acceptedAPQ11NeighborhoodCount')],
            [20,19,18,16,10])
        check_one(record)
        dense=amplitude_receipt(dense=True);check_one(dense)
        c=dense['result']['coverage']
        self.assertEqual(c['acceptedAmplitudeCount'],13)
        self.assertEqual(c['acceptedPairCount'],9)
        self.assertEqual(c['acceptedAPQ11NeighborhoodCount'],0)
        self.assertEqual(c['rejections']['amplitudeRatioPairs'],2)
        self.assertEqual(c['rejections']['discontinuousPairs'],8)
        self.assertIsNone(dense['result']['apq11'].get('value'))

    def test_rehashed_wrong_values_counts_units_or_profile_cannot_become_expectations(self):
        for kind in ('amplitudes','rolling'):
            good=amplitude_receipt(kind,True); check_one(good)
            mutations=[
                lambda r:r['configuration'].__setitem__('maximumAdjacentPeriodFactor',2),
                lambda r:r['profileIdentity'].__setitem__('sha256','0'*64),
                lambda r:r.__setitem__('amplitudeInputSHA256','0'*64),
                lambda r:r.__setitem__('inputAmplitudeCount',0),
                lambda r:r.__setitem__('preparedCombinedBufferBytes',0),
                lambda r:r.__setitem__('preparedSeparateBufferBytes',1),
                lambda r:r.__setitem__('preparedInputBytes',1),
                lambda r:r.__setitem__('frameSampleCount',1),
                lambda r:r.__setitem__('hopDefinition','none'),
                lambda r:r['result']['local'].__setitem__('value',.9),
                lambda r:r['result']['db'].__setitem__('unit','fraction'),
                lambda r:r['result']['apq3'].__setitem__('status','unavailable'),
                lambda r:r['result']['coverage'].__setitem__('acceptedPairCount',0),
                lambda r:r['result']['coverage']['rejections'].__setitem__('excluded',0),
                lambda r:r['result']['coverage'].__setitem__('acceptedPairDurationSeconds',0),
                lambda r:r['result']['dependencyTiming'].__setitem__('includedSampleCount',0),
                lambda r:r['result']['query'].__setitem__('startSeconds',.125),
                lambda r:r['checksums'].pop('Combined'),
                lambda r:r['checksums'].__setitem__('Combined',0),
            ]
            for mutate in mutations:
                bad=copy.deepcopy(good); mutate(bad)
                with self.assertRaises(ValueError): check_one(bad)

    def test_rolling_receipts_require_actual_bounded_scan_work_and_exact_window_identity(self):
        good=amplitude_receipt('rolling'); check_one(good)
        for mutate in [
            lambda r:r.__setitem__('observedAppendCount',1),
            lambda r:r.__setitem__('observedQueryCount',1),
            lambda r:r.__setitem__('measuredAmplitudeUpdates',0),
            lambda r:r.__setitem__('evaluatedAmplitudes',0),
            lambda r:r.__setitem__('evaluatedAmplitudes',10**9),
            lambda r:r['result']['sampleAlignedQuery'].__setitem__('startSample',0),
            lambda r:r.__setitem__('windowSampleCount',1),
        ]:
            bad=copy.deepcopy(good); mutate(bad)
            with self.assertRaises(ValueError): check_one(bad)

    def test_incomplete_duplicate_or_extra_matrix_rows_fail(self):
        row=amplitude_receipt()
        with self.assertRaises(ValueError): receipts.validate_matrix([])
        with self.assertRaises(ValueError): receipts.validate_matrix([row])
        with patch.object(receipts,'expected_cases',return_value={row['name']:row['workload']}):
            with self.assertRaises(ValueError): receipts.validate_matrix([row,row])
            bad=copy.deepcopy(row);bad['name']='invented'
            with self.assertRaises(ValueError): receipts.validate_matrix([bad])

    def test_oracle_rejects_invalid_observations_instead_of_producing_zero(self):
        row=amplitude_receipt();profile=row['configuration'];query=row['result']['query']
        original=oracle.generated_amplitudes(row['workload'])
        mutations=[lambda p:p[0].__setitem__('amplitude',-1),
            lambda p:p[1].__setitem__('timeSeconds',-1),
            lambda p:p[0].__setitem__('runID',True),
            lambda p:p[0].__setitem__('timeSeconds',float('nan')),
            lambda p:p[0].__setitem__('amplitude',10**1000),
            lambda p:p[0]['rejections'].__setitem__('rawValue',256)]
        for mutate in mutations:
            bad=copy.deepcopy(original);mutate(bad)
            with self.assertRaises(ValueError): oracle.evaluate(bad,query,profile)

    def test_distribution_controls_and_steady_state_allocations_fail_closed(self):
        matrix=[amplitude_receipt('rolling'),dict(name='pcm-fixture',operations=receipts.OPERATIONS['pcm'])]
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

    def test_pcm_receipts_retain_exact_source_f0_amplitudes_and_memory_geometry(self):
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
            lambda r:r['pcm']['mappedAmplitudes'].pop(),
            lambda r:r['pcm']['mappedAmplitudes'][0].__setitem__('timeSeconds',.1),
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
        matrix=[amplitude_receipt()]
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
        row=amplitude_receipt('rolling')
        values={f"Shimmer.{op}.{row['name']} - Time (wall clock)":cost for op,cost in
                [('Prepare',10000),('Combined',20000),('Separate',60000),('QueryOnly',100)]}
        costs=receipts.operation_costs([row],values)[row['name']]
        self.assertEqual(costs['separateToCombinedRatio'],3)
        self.assertEqual(costs['amortizedNanosecondsPerUpdateAndQuery'],1000)
        self.assertEqual(costs['queryOnlyNanoseconds'],100)
        values[f"Shimmer.Combined.{row['name']} - Time (wall clock)"]=0
        with self.assertRaises(ValueError):receipts.operation_costs([row],values)


if __name__=='__main__':unittest.main()
