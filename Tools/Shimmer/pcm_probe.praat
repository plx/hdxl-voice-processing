# Original public-command wrapper, no external implementation source.
form Shimmer from PCM and injected F0
    sentence Input
    sentence Pitch_file
    real Query_start 0
    real Query_end 0.5
    positive Period_floor 0.0001
    positive Period_ceiling 0.02
    positive Maximum_period_factor 1.3
    positive Maximum_amplitude_factor 1.6
endform
sound = Read from file: input$
rate = Get sampling frequency
samples = Get number of samples
pitch = Read from file: pitch_file$
selectObject: sound, pitch
pulses = To PointProcess (cc)
count = Get number of points
appendInfoLine: "begin", tab$, "shimmer-pcm-v1"
appendInfoLine: "input", tab$, rate, tab$, samples
appendInfoLine: "settings", tab$, query_start, tab$, query_end, tab$, period_floor, tab$, period_ceiling, tab$, maximum_period_factor, tab$, maximum_amplitude_factor
appendInfoLine: "pulses", tab$, count
selected = 0
for i from 1 to count
    time = Get time from index: i
    appendInfoLine: "pulse", tab$, i, tab$, time
    if time >= query_start and time <= query_end
        selected += 1
    endif
endfor
appendInfoLine: "selected", tab$, selected
if selected < 3
    appendInfoLine: "amplitudes", tab$, "insufficientPulses", tab$, 0
    appendInfoLine: "queries", tab$, "skippedInsufficientPulses"
else
    selectObject: sound, pulses
    tier = To AmplitudeTier (period): query_start, query_end, period_floor, period_ceiling, maximum_period_factor
    count = Get number of points
    appendInfoLine: "amplitudes", tab$, "complete", tab$, count
    for i from 1 to count
        time = Get time from index: i
        amplitude = Get value at index: i
        appendInfoLine: "amplitude", tab$, i, tab$, time, tab$, amplitude
    endfor
    value = Get shimmer (local): period_floor, period_ceiling, maximum_amplitude_factor
    appendInfoLine: "tier-local", tab$, value
    selectObject: sound, pulses
    value = Get shimmer (local): query_start, query_end, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    appendInfoLine: "sound-local", tab$, value
    selectObject: tier
    value = Get shimmer (local_dB): period_floor, period_ceiling, maximum_amplitude_factor
    appendInfoLine: "tier-db", tab$, value
    selectObject: sound, pulses
    value = Get shimmer (local_dB): query_start, query_end, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    appendInfoLine: "sound-db", tab$, value
    selectObject: tier
    value = Get shimmer (apq3): period_floor, period_ceiling, maximum_amplitude_factor
    appendInfoLine: "tier-apq3", tab$, value
    selectObject: sound, pulses
    value = Get shimmer (apq3): query_start, query_end, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    appendInfoLine: "sound-apq3", tab$, value
    selectObject: tier
    value = Get shimmer (apq5): period_floor, period_ceiling, maximum_amplitude_factor
    appendInfoLine: "tier-apq5", tab$, value
    selectObject: sound, pulses
    value = Get shimmer (apq5): query_start, query_end, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    appendInfoLine: "sound-apq5", tab$, value
    selectObject: tier
    value = Get shimmer (apq11): period_floor, period_ceiling, maximum_amplitude_factor
    appendInfoLine: "tier-apq11", tab$, value
    selectObject: sound, pulses
    value = Get shimmer (apq11): query_start, query_end, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    appendInfoLine: "sound-apq11", tab$, value
    selectObject: tier
    value = Get shimmer (dda): period_floor, period_ceiling, maximum_amplitude_factor
    appendInfoLine: "tier-dda", tab$, value
    selectObject: sound, pulses
    value = Get shimmer (dda): query_start, query_end, period_floor, period_ceiling, maximum_period_factor, maximum_amplitude_factor
    appendInfoLine: "sound-dda", tab$, value
endif
appendInfoLine: "end", tab$, "shimmer-pcm-v1"
