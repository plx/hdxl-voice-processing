# Original external command wrapper. All expected spectrogram/flatness/tiers are
# produced by the pinned developer tool; no reference implementation is bundled.
form Speech activity reference
    sentence Input
    sentence Prefix
    positive Hop 0.01
    positive Long_window 0.3
    positive Short_window 0.1
    positive Low_frequency 70
    positive High_frequency 6000
    real Flatness_threshold -10
    real Relative_intensity -35
    positive Minimum_nonspeech 0.1
    positive Minimum_speech 0.1
endform
sound = Read from file: input$
analysis_width = max(0.02, 2 * hop)
spec = To Spectrogram: analysis_width, high_frequency, hop, 20, "Hanning (sine-squared)"
Save as short text file: prefix$ + "-spectrogram-before.txt"
flatness = Get long-term spectral flatness: long_window, short_window, low_frequency, high_frequency
Save as short text file: prefix$ + "-flatness.txt"
selectObject: spec
Save as short text file: prefix$ + "-spectrogram-after.txt"
appendInfoLine: "stages-complete"
selectObject: sound
grid = To TextGrid (speech activity, LTSF): hop, long_window, short_window, low_frequency, high_frequency, flatness_threshold, relative_intensity, minimum_nonspeech, minimum_speech, "non-speech", "speech"
Save as short text file: prefix$ + "-textgrid.txt"
appendInfoLine: "complete"
