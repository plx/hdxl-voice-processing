"""Fail-closed input, numerical, memory and distribution checks for jitter costs."""
import math

from jitter_reference import ROOT, canonical, digest, load_json
import performance_oracle as oracle

SHARDS = ('duration250', 'duration1000', 'duration3000', 'duration10000', 'pcm')
CONTROL = 'Capability.JitterAllocationARC'
ALLOCATIONS = ('mallocCountTotal', 'mallocBytesCount', 'objectAllocCount')
DIAGNOSTICS = (*ALLOCATIONS, 'freeCountTotal', 'retainCount', 'releaseCount')
METRIC_NAMES = ('Malloc (total)', 'Malloc (bytes total)', 'Object allocs', 'Free (total)', 'Retains', 'Releases')
OPERATIONS = dict(periods=['Prepare','Combined','Separate'],
                  rolling=['Prepare','Combined','Separate','QueryOnly'],
                  pcm=['Prepare','PulseOnly','PCMCombined','StatisticsOnly'])
EPOCH = dict(sequence=0, streamID='00000000-0000-0000-0000-000000000050')


def same(actual, expected, message):
    if canonical(actual) != canonical(expected):
        raise ValueError(message)


def expected_cases(shard=None):
    result = {}
    def add(kind, duration, hz, dense, precision):
        name = f'{kind}.{duration}ms.{hz}hz.{"dense" if dense else "accepted"}.{precision}'
        result[name] = dict(kind=kind, durationMilliseconds=duration, frequencyHz=hz,
                           denseRejections=dense, precision=precision, sampleRate=16000)
    for precision in ('float32','float64'):
        for hz in (80,600):
            for duration in (250,1000,3000,10000):
                for dense in (False,True):
                    for kind in ('periods','rolling'): add(kind,duration,hz,dense,precision)
            add('pcm',500,hz,False,precision)
    if shard is not None:
        if shard not in SHARDS: raise ValueError('Unknown jitter shard')
        result = {name: row for name,row in result.items()
                  if ('pcm' if row['kind']=='pcm' else f"duration{row['durationMilliseconds']}")==shard}
    return result


def expected_profile(row):
    result = dict(schemaVersion=1, sampleRate=row['sampleRate'], inputPrecision=row['precision'],
        arithmeticPrecision='float64', applicability='exploratoryRolling' if row['kind']=='rolling' else 'sustainedPhonation',
        minimumPeriodSeconds=.0001, maximumPeriodSeconds=.02, maximumAdjacentPeriodFactor=1.3,
        definition='hdxl-jitter-period-statistics-v1',
        denominatorDefinition='separateMeanRejectBothAdjacentRatiosRetainOutsideQueryContext',
        neighborhoodDefinition='completeConsecutivePeriodsWithinQueryWithoutStitching')
    if row['kind']=='rolling': result['rollingWindowSampleCount']=row['durationMilliseconds']*row['sampleRate']//1000
    return result


def identity(name, configuration):
    return dict(identifier=dict(name=name,version=1),sha256=digest(canonical(configuration)))


def interval(start, count, rate):
    return dict(epoch=EPOCH,startSample=start,sampleCount=count,sampleRate=rate)


def close(actual, expected, bound, message):
    if (actual is None) != (expected is None): raise ValueError(message+' availability')
    if expected is not None and (not oracle.finite(actual) or abs(actual-expected)>bound):
        raise ValueError(message+' value')


def validate_result(record, profile, periods, query, duration, input_count, timing, provenance, window=None):
    report = record['result']
    same(report['schemaVersion'],1,'Jitter result version changed')
    same(report['profile'],record['profileIdentity'],'Jitter result profile changed')
    same(report['applicability'],profile['applicability'],'Jitter applicability changed')
    same(report['query'],query,'Jitter query changed')
    same(report.get('sampleAlignedQuery'),window,'Jitter exact source window changed')
    same(report['dependencyTiming'],timing,'Jitter dependency timing changed')
    same(report['inputProvenance'],provenance,'Jitter input provenance changed')
    expected = oracle.evaluate(periods,profile,query)
    coverage = report['coverage']
    same(coverage['inputPeriodCount'],input_count,'Jitter input count changed')
    same(coverage['analyzedDurationSeconds'],duration,'Jitter analyzed duration changed')
    for key,value in expected['coverage'].items():
        if key in ('meanPeriodSeconds','acceptedPeriodDurationSeconds'):
            bound = expected['bounds']['seconds' if key=='meanPeriodSeconds' else 'totalSeconds']
            close(coverage.get(key),value,bound,'Jitter '+key)
        else: same(coverage[key],value,'Jitter membership/counts changed: '+key)
    for variant,value in expected['values'].items():
        estimate = report[variant]
        same(estimate['variant'],variant,'Jitter variant changed')
        same(estimate['unit'],'seconds' if variant=='absolute' else 'fraction','Jitter unit changed')
        same(estimate['status'],'available' if value is not None else 'unavailable','Jitter availability changed')
        if value is not None and estimate.get('unavailability') is not None:
            raise ValueError('Available jitter has an unavailability reason')
        close(estimate.get('value'),value,expected['bounds']['seconds' if variant=='absolute' else 'fraction'],
              'Independent jitter '+variant)
    return expected


def expected_pulse_profile(row, fixture):
    return dict(schemaVersion=1,sampleRate=row['sampleRate'],inputPrecision=row['precision'],arithmeticPrecision='float64',
        pitchFloorHz=20,pitchCeilingHz=fixture['reference']['pitch']['ceilingHz'],minimumPeriodSeconds=.0001,maximumPeriodSeconds=.02,
        maximumAdjacentPeriodFactor=1.3,support='completeInterval',definition='hdxl-acoustic-pulses-waveform-cc-v1',
        seedDefinition='voicedIntervalMidpointAbsoluteExtremumParabola',
        correlationDefinition='observedPairsFusedDotScaleSubnormalProductFiniteLagTableRightNeighborPeak',
        interpolationDefinition='threePointParabolaGeometricRangeFallback',amplitudeDefinition='hannRMSPointTwoNeighborPeriods',
        minimumReliableCurvature=128*math.ulp(1.),minimumRelativeVariation=64*math.ulp(1.))


def validate_pcm(record, row, profile):
    pcm = record['pcm']
    stem = f"gaussian-{row['sampleRate']}-{row['frequencyHz']}-{row['precision']}"
    path = ROOT/'Tests/HDXLVoiceProcessingTests/Fixtures/Pulses'/(stem+'.json')
    fixture = load_json(path); ref = fixture['reference']; pitch = ref['pitch']
    wave = path.with_suffix('.wav').read_bytes()
    same(pcm['fixture'],stem,'PCM fixture changed')
    for key,wanted in dict(fixtureSHA256=digest(path.read_bytes()),
        encodedInputSHA256=digest(wave),normalizedInputSHA256=digest(wave[56:])).items():
        same(pcm[key],wanted,'PCM input identity changed: '+key)
    same(pcm['encodedInputSHA256'],ref['inputSHA256'],'Frozen PCM hash changed')
    count = fixture['case']['sampleCount']; rate = row['sampleRate']; frames = len(pitch['frequenciesHz'])
    for key,wanted in dict(sampleCount=count,f0FrameCount=frames,
        f0FirstCenterSeconds=pitch['firstCenterSeconds'],f0StepSeconds=pitch['stepSeconds'],
        preparedContourBytes=frames*8).items(): same(pcm[key],wanted,'PCM geometry changed: '+key)
    pulse_profile = expected_pulse_profile(row,fixture)
    same(pcm['pulseConfiguration'],pulse_profile,'PCM pulse configuration changed')
    pulse_id=identity(pulse_profile['definition']+'-completeInterval',pulse_profile)
    contour=dict(schemaVersion=1,sampleRate=rate,sampleCount=count,firstCenterSeconds=pitch['firstCenterSeconds'],
        stepSeconds=pitch['stepSeconds'],ceilingHz=pitch['ceilingHz'],frequenciesHz=pitch['frequenciesHz'])
    contour_id=identity('hdxl-pulse-supplied-f0',contour)
    same(pcm['pulseProfile'],pulse_id,'Pulse identity changed')
    same(pcm['contourIdentity'],contour_id,'F0 identity changed')
    points = pcm['rawPulseTimesSeconds']; reference_points=ref['data']['pulseTimesSeconds']
    if len(points)!=len(reference_points) or not all(oracle.finite(p) for p in points):
        raise ValueError('PCM pulse population changed')
    error=max((abs(a-b)*rate for a,b in zip(points,reference_points)),default=0.)
    if error>1e-6: raise ValueError('PCM pulse locations differ from pinned reference')
    same(pcm['maximumReferenceErrorSamples'],error,'PCM error receipt differs')
    periods=pcm['mappedPeriods']
    if len(periods)!=max(0,len(points)-1): raise ValueError('PCM raw periods were removed')
    for i,p in enumerate(periods):
        same([p['startSeconds'],p['endSeconds']],[points[i],points[i+1]],'PCM period endpoints changed')
    capacity=4096+frames
    # Pinned arm64 Swift6.4 layouts: pulse64/period48/pair40/amplitude72/attempt120,
    # lag32; supplied jitter period32, numerical record16.
    pulse_bytes=count*8+capacity*(64+48+40+72)+4096*120+(math.ceil(.45*rate/20)+7)*32
    same(pcm['preparedPulseBufferBytes'],pulse_bytes,'Pulse workspace bytes changed')
    same(pcm['preparedStatisticsBufferBytes'],capacity*16,'PCM statistics bytes changed')
    same(record['preparedCombinedBufferBytes'],pulse_bytes+capacity*48,'PCM pipeline bytes changed')
    same(record['preparedSeparateBufferBytes'],0,'Unexpected separate PCM workspace')
    same(record['preparedInputBytes'],count*(4 if row['precision']=='float32' else 8)+len(periods)*32,
         'PCM owned input bytes changed')
    timing=dict(source=interval(0,count,rate),includedSampleCount=count,effectiveDelaySeconds=count/rate/2)
    provenance=dict(kind='acousticPulses',periodSourceProfile=pulse_id,f0ContourIdentity=contour_id)
    return periods,timing,provenance


def validate_matrix(matrix, shard=None):
    expected=expected_cases(shard)
    if not isinstance(matrix,list): raise ValueError('Missing jitter matrix')
    seen=set()
    for record in matrix:
        name=record['name']
        if name not in expected or name in seen: raise ValueError('Unexpected/duplicate jitter workload')
        seen.add(name); row=expected[name]; kind=row['kind']; rate=row['sampleRate']
        same(record['workload'],row,'Jitter workload recipe changed')
        profile=expected_profile(row)
        same(record['configuration'],profile,'Jitter configuration changed')
        same(record['profileIdentity'],identity(profile['definition']+'-'+profile['applicability'],profile),
             'Jitter profile fingerprint changed')
        same(record['operations'],OPERATIONS[kind],'Jitter operation coverage changed')
        frame=row['durationMilliseconds']*rate//1000
        n=row['durationMilliseconds']*row['frequencyHz']//1000
        same(record['frameSampleCount'],frame,'Jitter frame geometry changed')
        same(record.get('windowSampleCount'),frame if kind=='rolling' else None,'Jitter window geometry changed')
        same(record['measuredPeriodUpdates'],n if kind=='rolling' else 0,'Jitter update count changed')
        same(record['hopDefinition'],'oneCompletePeriodVariableSourceHop' if kind=='rolling' else 'wholeDeclaredInterval',
             'Jitter hop definition changed')
        if kind=='pcm':
            periods,timing,provenance=validate_pcm(record,row,profile)
        else:
            if record.get('pcm') is not None: raise ValueError('Unexpected PCM evidence')
            periods=oracle.generated_periods(row)
            capacity=n+2
            # Ring entry optional88; tree node352 = raw224 + reasons88 + sums32 + start8.
            # SourceInterval48 and AnalysisTiming112; no object bookkeeping claim.
            base=1<<(capacity-1).bit_length()
            prepared=capacity*16 if kind=='periods' else capacity*88+2*base*352
            same(record['preparedCombinedBufferBytes'],prepared,'Jitter workspace geometry changed')
            same(record['preparedSeparateBufferBytes'],5*prepared,'Separate workers were not prepared')
            same(record['preparedInputBytes'],len(periods)*(32+48+112),'Jitter input storage changed')
            end=math.ceil(periods[-1]['endSeconds']*rate)+1 if kind=='rolling' else frame
            timing=dict(source=interval(0,end,rate),includedSampleCount=end,effectiveDelaySeconds=0)
            provenance=dict(kind='suppliedPeriods')
        same(record['inputPeriodCount'],len(periods),'Jitter input population changed')
        same(record['periodInputSHA256'],oracle.period_hash(periods),'Jitter period input hash changed')
        clock=timing['source']['sampleCount']
        start=clock-frame if kind=='rolling' else 0
        query=dict(startSeconds=start/rate,endSeconds=clock/rate)
        selected=[p for p in periods if query['startSeconds']<=p['startSeconds'] and p['endSeconds']<=query['endSeconds']]
        retained=len(selected)+int(len(selected)<len(periods)) if kind=='rolling' else len(periods)
        window=interval(start,frame,rate) if kind=='rolling' else None
        validate_result(record,profile,periods,query,frame/rate,retained,timing,provenance,window)
        if kind=='rolling':
            same(record['observedAppendCount'],len(periods),'Rolling observations were not appended')
            same(record['observedQueryCount'],n,'Rolling intermediate queries were not executed')
            work=record['sumTreeNodeUpdates']; depth=(n+1).bit_length()+1
            if type(work) is not int or not len(periods)<=work<=6*len(periods)*depth:
                raise ValueError('Rolling sum-tree update work is absent or unbounded')
        elif any(record.get(k) is not None for k in ('observedAppendCount','observedQueryCount','sumTreeNodeUpdates')):
            raise ValueError('Unexpected rolling work counters')
        checksums=record['checksums']
        same(sorted(checksums),sorted(op for op in OPERATIONS[kind] if op!='Prepare'),'Unobserved jitter operations')
        if any(not oracle.finite(v) or v<=0 for v in checksums.values()):
            raise ValueError('Nonfinite or empty jitter operation output')
    if seen!=set(expected): raise ValueError('Missing jitter matrix coverage')
    return matrix


def benchmark_names(matrix, mode):
    names={f"Jitter.{op}.{row['name']}" for row in matrix for op in row['operations']}
    if mode=='allocation': names.add(CONTROL)
    return names


def validate_raw(raw, matrix, mode):
    expected=benchmark_names(matrix,mode)
    rows=raw['results']
    if not isinstance(rows,list) or len(rows)!=2*len(expected): raise ValueError('Missing/extra jitter distributions')
    required={'wallClock','cpuTotal'} if mode=='timing' else {'wallClock',*DIAGNOSTICS}
    result={}
    for i in range(0,len(rows),2):
        identity_row,measurements=rows[i:i+2]; name=identity_row['name']
        if name not in expected or name in result or identity_row['target']!='JitterBenchmarks':
            raise ValueError('Unexpected/duplicate jitter distribution')
        metrics={}
        for m in measurements:
            if len(m['metric'])!=1 or m['scalingFactor']!=1: raise ValueError('Unexpected metric scaling')
            metric=next(iter(m['metric'])); histogram=m['statistics']['histogram']
            count=histogram['_totalCount']; maximum=histogram['maxValue']; buckets=histogram['counts']
            if metric not in required or metric in metrics or type(count) is not int or count<30:
                raise ValueError('Missing/duplicate metric or fewer than thirty samples')
            if (type(maximum) is not int or maximum<0 or not isinstance(buckets,list) or not buckets
                    or any(type(v) is not int or v<0 for v in buckets) or sum(buckets)!=count):
                raise ValueError('Malformed jitter distribution')
            if metric=='wallClock' and maximum<=0: raise ValueError('No positive operation duration')
            if mode=='allocation':
                if name==CONTROL and metric in DIAGNOSTICS and maximum<=0:
                    raise ValueError('Unavailable allocation/ARC capability: '+metric)
                if name.startswith('Jitter.') and '.Prepare.' not in name and metric in ALLOCATIONS and maximum!=0:
                    raise ValueError(f'Steady-state allocation: {name}, {metric}, maximum={maximum}')
            metrics[metric]=dict(sampleCount=count,maximum=maximum)
        if set(metrics)!=required: raise ValueError('Missing jitter metric coverage')
        result[name]=metrics
    return result


def validate_export(rows,names,mode):
    metrics=('Time (wall clock)','Time (total CPU)') if mode=='timing' else ('Time (wall clock)',*METRIC_NAMES)
    expected={f'{name} - {metric}' for name in names for metric in metrics}
    result={}
    for row in rows:
        name,value=row['name'],row['value']
        if name not in expected or name in result or not oracle.finite(value) or value<0:
            raise ValueError('Invalid/duplicate jitter p99 export')
        same(row['unit'],'ns' if ' - Time (' in name else '#','Unexpected jitter metric unit')
        result[name]=value
    if set(result)!=expected: raise ValueError('Missing jitter p99 metrics')
    return result


def operation_costs(matrix,values):
    result={}
    for row in matrix:
        costs={op:values[f"Jitter.{op}.{row['name']} - Time (wall clock)"] for op in row['operations']}
        if any(not oracle.finite(v) or v<=0 for v in costs.values()): raise ValueError('Missing positive jitter cost')
        kind=row['workload']['kind']; seconds=row['workload']['durationMilliseconds']/1000
        detail=dict(statistic='p99 of thirty retained operation samples; near maximum, not stable tail estimate',
            operationNanoseconds=costs,preparedBufferBytes=row['preparedCombinedBufferBytes'])
        if kind!='pcm':
            detail.update(separateToCombinedRatio=costs['Separate']/costs['Combined'],
                inputSecondsPerWallSecond=seconds/(costs['Combined']*1e-9))
        if kind=='rolling':
            detail['amortizedNanosecondsPerUpdateAndQuery']=costs['Combined']/row['measuredPeriodUpdates']
            detail['queryOnlyNanoseconds']=costs['QueryOnly']
        if kind=='pcm':
            detail.update(inputSecondsPerWallSecond=seconds/(costs['PCMCombined']*1e-9),
                scope='Direct pulse-only, combined PCM and statistics-only measurements on the same input; no subtraction-derived stage timing')
        result[row['name']]=detail
    return result
