# Black-box reference export. Both passes receive the identical source and settings.
form Formant reference
    sentence Input
    positive Hop_seconds
    integer Order
    positive Ceiling_hz
    positive Effective_window_seconds
    positive Pre_emphasis_hz
endform
sound = Read from file: input$
for pass from 1 to 2
    selectObject: sound
    if pass = 1
        formant = To Formant (keep all): hop_seconds, order / 2, ceiling_hz, effective_window_seconds, pre_emphasis_hz
    else
        formant = To Formant (burg): hop_seconds, order / 2, ceiling_hz, effective_window_seconds, pre_emphasis_hz
    endif
    frames = Get number of frames
    appendInfoLine: "pass", tab$, pass, tab$, frames
    for i from 1 to frames
        time = Get time from frame number: i
        n = Get number of formants: i
        appendInfoLine: "frame", tab$, i, tab$, time, tab$, n
        for j from 1 to n
            f = Get value at time: j, time, "Hertz", "Linear"
            b = Get bandwidth at time: j, time, "Hertz", "Linear"
            appendInfoLine: "pole", tab$, j, tab$, f, tab$, b
        endfor
    endfor
endfor
