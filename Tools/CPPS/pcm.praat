# Original command wrapper. The pinned external executable creates the cepstrogram.
form PCM CPPS reference
    sentence Input
    sentence Object_output
    sentence Probe_script
    positive Construction_floor 60
    positive Hop 0.002
    positive Maximum_frequency 5000
    real Preemphasis 50
    real Time_window 0.01
    real Q_window 0.001
    boolean Pretrend no
    positive Tolerance 0.05
endform
Read from file: input$
To PowerCepstrogram: construction_floor, hop, maximum_frequency, preemphasis
Save as short text file: object_output$
runScript: probe_script$, object_output$, time_window, q_window, pretrend, tolerance, "no"
