# Visualization consumer

An independent package depending only on the optional visualization product. Core
result types are its transitive dependency. It creates deterministic synthetic
histories and owned waveform buffers, then measures validation and main-actor
publication with one Observation subscriber. It never initializes capture, runs DSP,
requests permissions or renders a plot.

Run `python3 Tools/Visualization/benchmark.py --output .build/visualization-evidence`
from the repository root for five fresh release processes, environment/source
provenance, distributions and evidence validation. See
[the evidence guide](../../Tools/Visualization/README.md) for the timed boundaries.
