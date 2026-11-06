# ADR 0004: One numerical scheduler with explicit continuity and population

Status: MVP implementation in #40; owner attention #123. Physical evidence remains #74.

The numerical worker composes existing prepared kernels rather than duplicating their
framing, conditioning or statistics in each input path. File/batch and PCMTransfer
adapters belong to Audio; scheduling and immutable mask consumption remain in Core.
All work is synchronous and single-owner. Actor/session/subscriber lifecycle remains
the responsibility of subsequent roadmap work and host applications.

Fixed source tiles make dispatch order deterministic under caller chunking, at the cost
of separately declared bounded batching. Tile size is a resource/delivery choice, not
part of the numerical profile hash. A complete composition hash includes input format,
channel conversion and every enabled numerical recipe. Native results also retain
individual algorithm identities. Composition hashes deliberately change when another
lane is enabled; finer independent lane composition identities can be added if needed.

Capture epoch and analysis continuity epoch are separate identities. Each continuous
analysis region starts its local grid at zero, while output maps to exact original
source sample positions. Optional clocks are nominal-rate anchor projections. No
fabricated timestamp, zero-filled loss, hardware drift correction or measured latency
is implied. CPPS frame center and complete dependency support remain separate concepts.
Filter/tracker histories, warm-up and centered future support are explicit requirements.

Finite and continuous delivery may share a numerical recipe only when its applicability
allows it. Whole-interval CPPS requires a declared finite interval. Preview uses finite
FIR conditioning and its own recipe identity; continuous requests never substitute it
silently. Global mask decisions require a completed/two-pass immutable plan.

Existing masks select original contiguous regions. Every region finalizes/resets all
dependent state. Raw eligible analysis and selected analysis retain separate population
provenance, unique source coverage and independent evidence tags. Pitch unavailability
does not vote against speech. Numerical region aggregates are emitted individually;
no undocumented cross-region weighting is introduced. Prefix counts avoid rescanning
long history or allocating coverage arrays per frame.

The standard scheduler owns only bounded scratch and scalar output metadata. Consumers
must explicitly bound retained frame history. Kernel diagnostic curves/candidates remain
borrowed through their low-level APIs. Exporting owned scalar results is an explicit
boundary; the full export preserves dependency coverage and mask provenance. Input-file
decoder provenance is separate from the measurement recipe because system codec behavior
is outside the numerical core's implementation and allocation guarantee.

Ordinary reset reuses streaming scratch; different whole-interval sizes reconfigure at
region boundaries. Cooperative cancellation preserves active borrows and stops further
emission. Each batch file gets a separate worker, so failure/cancellation cannot pollute
later files. New files/seeks and changed input formats get fresh prepared instances.

See [the API and timing guide](../SharedScheduling.md) for limits, error behavior,
coverage semantics, decoder provenance and the source-tile delay contract.
