# Visualization consumer

This independent Swift package depends on the optional visualization product and uses its transitive Core types.

The adapter benchmark creates deterministic synthetic histories and owned waveform buffers and measures validation and main-actor publication with one Observation subscriber. Run `python3 Tools/Visualization/benchmark.py --output .build/visualization-evidence` for five fresh Release processes and source and environment records.

The inspector benchmark runs the real YIN processor on identical synthetic PCM windows with processor-only, disabled, selected and bounded sampled capture. Run `python3 Tools/Visualization/inspector.py --output .build/inspector-evidence` for three trials in fresh Release processes. Each trial records raw timings, retained payloads, peak memory growth and changes relative to its processor-only run. [Evidence guide](../../Tools/Visualization/README.md) · [Inspector guide](../../Documentation/AlgorithmInspector.md)
