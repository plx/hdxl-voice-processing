# Personal target feedback

`PersonalTargetFeedback` turns fresh, compatible observations of an accepted
[personal target](PersonalTargets.md) into an inspectable temporal state. It does
not fit a target, infer vocal health or tension, prescribe effort, or trigger
colors, sound or haptics. The core package has no UI or microphone dependency.

Create one policy on its owning worker/control context, before display delivery:

```swift
let feedback = try PersonalTargetFeedback(target: acceptedModel)
let displayResults = try feedback.subscribe(.newest(capacity: 1))

let evidence = try PersonalTargetFeedbackEvidence(
    take: completedTake,
    analysis: completedAnalysis,
    sourceEndHostNanoseconds: sourceEnd
)
let snapshot = try feedback.update(evidence)
// Present snapshot.state.text and inspect its reasons/responsibleFeature.
// A consumer can also observe displayResults asynchronously.
```

`sourceEnd` is the host's monotonic timestamp at the end of the actual source
support. It is not the time this call completes or a UI observes a publication.
File replay must supply an explicit virtual source-to-clock mapping and an injected
clock in the same domain. Never use wall-clock calendar time. The default clock is
`DispatchTime.now().uptimeNanoseconds`. Construction verifies that positive source
duration fits before its supplied end anchor; hosts remain responsible for truthful
anchors and complete source metadata.

The policy is single-owner and deliberately not `Sendable`. Subscriptions and
immutable snapshots are `Sendable`. Feed the policy every complete observation
before applying display coalescing. A missing input interval is not reconstructed
from the most recently delivered value. Do not call observation construction,
policy updates, subscription operations or formatting from a capture callback.

## Preserve the fitted observation

An observation is the declared `selectedIntervalLowerMedianV1` statistic of a
complete, validated calibration analysis. The evidence constructor validates the
take/analysis pair, hashes the analysis and resolves its existing mask algebra.
It retains bounded summaries and provenance, without PCM or frame history.
Preparation allocates and belongs outside the policy update benchmark.

The policy binds the accepted model's complete identity, exact executable profile,
analysis implementation, statistic, task and recording conditions. It scores CPPS
in raw ratio dB; configuration rejects CPP, fractional/percent values and other
units. There is no conversion, implicit model activation or changed threshold.
The target's observed CPPS, pitch and recording-level supports still apply.

The supplied validated target example uses whole-interval, noncausal CPPS. One live
frame is not that statistic; a streaming-preview profile is not that profile.
Another executable profile may be used only with its own exact validation and
accepted fit. This policy does not transfer validation between those cases. The
[phonation study](https://pubmed.ncbi.nlm.nih.gov/40021420/) describes task-dependent
relationships; it does not establish this policy's engineering timing defaults or
a universal personal target.

`snapshot.profile` is the profile required by the target. The actual input profile,
analysis implementation, statistic, analysis digest, source interval, clock anchor
and coverage remain in `snapshot.evidence`, including for incompatible inputs.
Known missing-acquisition intervals have no invented measurement provenance.

## States and transitions

| State | Default visible text | Meaning |
| --- | --- | --- |
| `unavailable` | Feedback unavailable | Missing, expired, invalid or incompatible evidence, or a lifecycle control |
| `uncertain` | Insufficient evidence | Warmup, initial departure persistence, uncertain input, or values outside validated support |
| `approachingTarget` | Target match pending | A preferred-range match is accumulating entry evidence or awaiting cooldown |
| `onTarget` | Within your target | An established match, possibly retained by an explicitly reported exit rule |
| `departedTarget` | Target drift | An established departure within the model's observed support |

The visible text does not require a color legend. Hosts may localize it and add
shapes or other cues; color alone must not carry the meaning
([WCAG Use of Color](https://www.w3.org/WAI/WCAG22/Understanding/use-of-color.html)).
Machine-readable `reasons`, `modelReasons` and `responsibleFeature` provide the
explanation. These core values do not establish that a host UI is accessible.

The preferred interval is inclusive and remains exactly as fitted, including a
zero-width interval. A valid CPPS zero can match a zero-containing target; an
unavailable value has no number. An established match may remain latched inside
the preferred interval plus `exitMarginDB`, clipped to observed training support.
This is reported as `hysteresisHeld`. Outside that retained range, exit persistence
and cooldown apply. Pending exits remain `onTarget` with `exitPersistence` and/or
`cooldown`; `proximity` exposes the current contrary summary. Entry never uses the
widened exit margin. `approachingTarget` means a pending match, not a claim that a
physical voice parameter is trending in a particular direction.

The first classified state and subsequent changes require the configured evidence
duration and observation count. Warmup and candidate persistence accumulate from
the same qualifying intervals and are independent gates, not sequential delays.
An initial outside-range observation remains uncertain until departure persistence
passes. Cooldown starts at the source-end anchor of a classified transition;
invalid applicability bypasses it and clears temporal state immediately.

Defaults are explicit engineering choices pending review in
[#142](https://github.com/plx/hdxl-voice-processing/issues/142):

| Control | Default |
| --- | --- |
| Warmup | 0.25 seconds |
| Entry / exit persistence | 0.5 / 0.5 seconds |
| Minimum observations per transition | 2 |
| Minimum time between classified transitions | 1 second |
| Maximum source-evidence age | 2 seconds |
| Exit margin | 0.5 dB |

Durations are bounded configuration, not clinical recommendations or guarantees of
independent statistical observations. Choose freshness limits that suit the actual
summary cadence and processing delay. A summary cadence longer than maximum age
cannot keep an established match continuously valid.

## Source time, coverage and faults

Only non-overlapping, advancing source intervals can add evidence. Integer selected
sample counts are accumulated before conversion to seconds, preserving short
intervals at large source offsets. A repeated analysis/interval is a duplicate even
if its host anchor is relabeled. Other overlapping or reversed intervals, or
non-advancing source-end anchors, are rejected without replacing the latest accepted
evidence. Epoch/rate changes restart temporal state and per-epoch coverage. Source
holes restart temporal state and count as `unobservedSamples`; that does not claim
PCM was dropped.

Persistence credits selected support of qualified summaries. It is not a measured
duration during which every underlying frame stayed inside the target. The lower
median does not establish that property. `matchingSummarySamples` has that same
summary-level meaning. Full source, eligible, selected, missing, excluded and
unobserved counts remain separate. `qualifiedFraction` retains the whole source
denominator and becomes absent if its counters saturate. Tag counts overlap and
must not be added to infer unique coverage.

Whole-source tags remain visible, while `selectedTags` identifies tags in the
selected analysis support. Selected silence, suspected external noise, clipping,
non-speech or energy-ineligible capture prevent a target judgment. An explicitly
tagged low-periodicity or algorithm-insufficiency condition is uncertain, not
silence. Excluded silence/noise remains in coverage and does not masquerade as
selected vocal evidence. Any missing acquisition invalidates continuity; a merely
low but available CPPS value is judged against the accepted model, not automatically
labeled silence or noise.

Applicability priority is model/task/recording context, capture conditions,
coverage/availability, pitch support, recording-level support, then CPPS support.
All applicable findings are retained, with a deterministic responsible feature.
Pitch, level and coverage are gates; their values are not averaged with CPPS.
Unavailability within one required metric identifies that metric. The model's
warnings, observation counts, boundary and coverage requirements remain in force.

Call `poll()` from a host timer or replay driver to expire evidence at the exact
maximum-age boundary. Polling cannot add persistence or complete a pending match.
Updates also check expiry, so a missing timer callback cannot preserve a stale
latch. Reversed/future clocks produce `invalidClock`. Fresh evidence is required
after an invalidating condition; fixing the clock alone does not restore a match.

## Lifecycle and bounded delivery

`recordGap` accepts known dropped source support without inventing zero-valued
measurements. `reset(.droppedAudio)` records an unknown-extent loss event. Other
reset causes distinguish missing input, manual reset, route, profile and source
discontinuity. Reset clears temporal evidence and coverage but retains the source
admission watermark. Replaying the previous observation cannot rebuild a match.

`pause()` discards temporal evidence; ordinary observations are ignored until
`resume()`. Explicit gap reports still retain known loss while paused. A changed
accepted target is installed explicitly with `replaceTarget`, which clears temporal
evidence and coverage. A route/profile change does not make the old target applicable
to the new context. `finish(cancelled:)` publishes terminal unavailability, then
finishes subscribers exactly once. Further updates and resets throw; repeated finish
or poll calls return the terminal snapshot.

Observers use the existing [bounded delivery contract](ResultDelivery.md): at most
64 independent subscribers, newest-snapshot coalescing or explicit overflow failure.
Slow displays, stalled strict sinks and subscription churn cannot alter policy
state. Consumers receive the already-computed source evidence and durations; their
publication/observation clocks do not advance the policy.

The shared instrumentation vocabulary includes `FeedbackStateChange` with an opaque
policy token. Policy state/reason/feature/model changes produce optional signposts;
unchanged numeric updates do not produce policy-transition records. Delivery retains
its separate optional instrumentation. The default mode is disabled. No personal
measurement, model digest, prompt, label, route identifier or raw audio is placed
in ordinary diagnostics. Explicit snapshots are personal data owned by the host.

## Reproducible software evidence

Run `python3 Tools/PersonalTargets/feedback.py --output .build/personal-feedback-evidence`
from a fresh output destination. The probe retains 54 optimized trials across
4, 40 and 1,000 virtual updates per second, zero or 64 observers, and all three
diagnostic modes. Raw update costs, separately measured preparation, output
digests and exact buffer/delivery counts are audited. Every mode and observer
configuration must produce identical policy snapshots at each source cadence.
No wall-clock sleep simulates a device deadline. The short synthetic summaries
stress the policy; they do not validate DSP at those durations. Timing boundaries
and artifact interpretation are detailed in [the evidence tools](../Tools/PersonalTargets/README.md).

The [standalone public API example](../Examples/PersonalTargetWorkflow/README.md)
also checks entry persistence, duplicate rejection, exact stale expiry and
termination for every activated synthetic fitting scenario, using the separately
validated whole-interval profile. Scripted unit tests cover selected/excluded
capture tags, metric conflicts, valid zero, source gaps, large source offsets,
pause/reset/model changes, cancellation and bounded consumers.

Physical capture/display latency, thermal/energy effects and personal-workflow
acceptance remain pending in [#74](https://github.com/plx/hdxl-voice-processing/issues/74)
and [#142](https://github.com/plx/hdxl-voice-processing/issues/142).
