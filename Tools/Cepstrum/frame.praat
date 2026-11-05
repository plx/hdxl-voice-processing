# Original independent intermediate route. Input contains one conditioned frame.
# Public Praat commands demean/window it before the spectrum operation. No native
# Swift numerical output enters this workflow.
form Cepstral frame reference
    sentence Input
endform
sound = Read from file: input$
count = Get number of samples
appendInfoLine: "begin", tab$, "cepstral-frame-v2", tab$, count
Subtract mean
Multiply by window: "Gaussian2"
for i from 1 to count
    value = Get value at sample number: 1, i
    appendInfoLine: "windowed", tab$, i - 1, tab$, value
endfor
spectrum = To Spectrum: "yes"
matrix = To Matrix
bins = Get number of columns
appendInfoLine: "bins", tab$, bins
usable = 1
for i from 1 to bins
    re = Get value in cell: 1, i
    im = Get value in cell: 2, i
    power = 2 * (re * re + im * im)
    if i = bins
        logarithm = ln (power)
        if power = 0
            usable = 0
        endif
    else
        logarithm = ln (power + 1e-300)
    endif
    appendInfoLine: "spectrum", tab$, i - 1, tab$, re, tab$, im, tab$, power, tab$, logarithm
endfor
if usable
    selectObject: spectrum
    Formula: ~ if row = 1 then ln (2 * (self [1, col]^2 + self [2, col]^2) + if col = ncol then 0 else 1e-300 fi) else 0 fi
    cepstrum = To Sound
    for i from 1 to bins
        value = Get value at sample number: 1, i
        appendInfoLine: "cepstrum", tab$, i - 1, tab$, value, tab$, value * value
    endfor
else
    for i from 1 to bins
        appendInfoLine: "cepstrum", tab$, i - 1, tab$, "--undefined--", tab$, "--undefined--"
    endfor
endif
appendInfoLine: "end", tab$, "cepstral-frame-v2"
