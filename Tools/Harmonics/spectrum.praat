# Independent rectangular whole-period spectrum. Sound samples are normalized PCM.
form Harmonic bins
    sentence Input_file
    integer Periods
endform
snd = Read from file: input_file$
duration = Get total duration
spectrum = To Spectrum: "no"
matrix = To Matrix
for h from 1 to 2
    bin = h * periods + 1
    re = Get value in cell: 1, bin
    im = Get value in cell: 2, bin
    amplitude = 2 * sqrt(re * re + im * im) / duration
    appendInfoLine: h, tab$, amplitude
endfor
