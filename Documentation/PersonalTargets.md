# Personal targets

`PersonalTargetFitter` proposes a small, inspectable association between one person's
listening labels and CPPS. It evaluates complete unseen recordings and complete
later sessions before returning an `ActivatedPersonalTarget`. Refusing activation
is a useful result. The model does not diagnose a condition, estimate a probability,
prescribe vocal effort, or define a universally desirable voice.

The MVP uses CPPS in raw dB. Raw F0 and unweighted recording dBFS provide context;
selected-audio and metric-availability fractions expose possible selection effects.
HNR is not included without evidence that it adds useful information. The
[phonation comparison](https://pmc.ncbi.nlm.nih.gov/articles/PMC13252592/) and
[CPP interpretation study](https://pmc.ncbi.nlm.nih.gov/articles/PMC7893528/) motivate
checking task, pitch and recording level. Their clinical cutoffs are not personal
preference thresholds, and their findings do not validate this model's engineering
defaults. Owner policy review is tracked in [#128](https://github.com/plx/hdxl-voice-processing/issues/128).

## Fit, freeze, evaluate

Start with the immutable, listening-labeled [calibration dataset](Calibration.md)
and its validated whole-recording/session split. Select a training reference take
and policy before examining evaluation measurements. Supply separate dictionaries
of complete analysis records to the two stages:

```swift
let fit = try PersonalTargetFitter.fit(
    dataset: dataset,
    split: split,
    trainingAnalyses: trainingAnalyses,
    referenceTakeID: referenceTakeID,
    validation: checkedProfileEvidence,
    policy: PersonalTargetPolicy()
)

let evaluation = try PersonalTargetFitter.evaluate(
    fit,
    dataset: dataset,
    split: split,
    evaluationAnalyses: heldOutAnalyses
)

if let model = evaluation.activated {
    let observation = try PersonalTargetObservation(take: newTake, analysis: newAnalysis)
    let prediction = model.prediction(for: observation)
    // A nil predicted class means abstention; show its reasons and context.
}
```

`checkedProfileEvidence` represents actual passing reference and chunk/boundary
artifacts for the exact executable CPPS/F0/level profile and calibration-analysis
implementation. It is not a flag to set because another algorithm issue closed.
`PersonalTargetValidationEvidence` requires all three metrics, positive checked-case
counts, and finite error/budget ratios in 0...1. The host retains and verifies the
artifacts identified by their digests. A caller can fabricate provenance values;
these contracts do not authenticate external measurements or attest that a study
was performed. The software evidence workflow must validate the retained artifacts
and successful test process before constructing receipts.

Passing held-out analysis keys to `fit`, training keys to `evaluate`, or unrelated
keys to either throws. Missing records stay in reports as abstentions. Evaluation
never changes the candidate's bounds, scaling, context rules or training identity.
Changing held-out data requires a new dataset/split/fit version; when training
inputs and policy are unchanged, the numerical rule and training identity remain
unchanged. Full dataset, split, validation, fit and evaluation identities still
record that a different evaluation was performed. Repeatedly selecting versions
after inspecting holdouts would introduce selection bias; the API does not make
such a process an independent study.

## The numerical rule

Each eligible take contributes the lower empirical median of its available CPPS,
raw F0 and dBFS observations. At least three available observations and the declared
coverage/availability requirements are needed. Missing values are never zeroes.
For sorted values, quantile `q` is the element at one-based rank `ceil(q * n)`;
the median of an even count is the lower central observation.

The existing acquisition/content grouping keeps original-recording aliases and
identical-media aliases in one statistical group and split role. Identical analysis
keys and records contribute only once to the group's lower median. Different
analyses in that group are summarized into one group point, not treated as separate
independent trials. Conflicting labels, session metadata or alias analyses reject
the group. One rejected alias conservatively rejects its group. Each take's source,
eligible and selected coverage remains visible; overlapping excerpts are not added
into a fictitious unique-source total.

On training preferred groups, fit the interval
`[Q1 - 1.5 * IQR, Q3 + 1.5 * IQR]`, clipped to the CPPS support observed across
eligible training groups of both classes. The multiplier is explicit policy.
Inside the inclusive interval predicts preferred; outside predicts usual, provided
CPPS, F0 and dBFS remain inside their respective observed training supports. Values
beyond that support abstain. There is no amplitude normalization, hidden epsilon,
extrapolation, or subsequent widening. A zero-width preferred interval remains
zero width. Arithmetic overflow refuses the fit instead of constructing an infinite
interval. Outliers remain visible in distributions, predictions and error counts.

The candidate reports whether usual examples lie below, above, on both sides, or
overlap the preferred interval. This direction comes from the supplied personal
labels. It is not an instruction to raise or lower CPPS. Distribution counts,
quartiles, extrema, raw-unit scaling and the fitting procedure are serialized.

## Scope, confounds and activation

The reference selects one exact task/prompt, executable profile and known recording
conditions: route, room, microphone distance, input gain and recording settings.
Notes are retained but are not a numerical recording condition. Different wording,
routes/profiles or unknown conditions are out of scope and abstain. Reports retain
both overall and in-scope denominators, plus the out-of-scope groups. Activation
uses the cohort chosen before fitting. Missing, excluded, uncertain, exposed-label
and low-quality records within that cohort remain abstentions in its denominator.
An evaluation consisting only of domain shifts cannot satisfy the required cohort
or later-session counts.

Defaults are configurable engineering requirements, not validated clinical or
statistical sample-size recommendations:

| Requirement | Default |
| --- | --- |
| Eligible training acquisition groups per class | 4 |
| Groups per class in each pooled holdout role | 4 |
| Later held-out sessions with both classes | 2 |
| Training and each holdout balanced accuracy | at least 0.8 |
| Each represented later session balanced accuracy | at least 0.8 |
| Abstention fraction within the selected cohort | at most 0.2 |
| Selected source fraction and each metric's available fraction | at least 0.5 |
| Available observations per required metric | at least 3 |
| Available observations carrying boundary/partial-coverage warnings | at most 0.25 |
| Minimum listening-label confidence | 0; no confidence weighting |

Non-boundary warnings such as clipping, low confidence and exploratory applicability
reject a take. Positive confidence thresholds require a known confidence meeting
that threshold. Preferred/usual labels must have been recorded before feature
exposure; other and uncertain labels are reported without conversion to either class.

Context-only rules fit the same preferred-band procedure on training F0, dBFS,
selected fraction, and each required metric's availability fraction. Their frozen
rules are evaluated on training and both holdout roles and on later sessions. A
context rule with balanced accuracy at least 0.8 and within 0.05 of the CPPS rule
blocks activation as a possible confound. This detects an association, not its
cause. Failure to detect this simple association does not prove absence of nonlinear,
combined or unmeasured confounds. dBFS is recording level, not calibrated sound
pressure or a direct measure of vocal effort.

## Read the errors and uncertainty

Every partition includes class counts, confusion counts, per-class abstentions,
coverage, error-group identities and abstained-group identities. Recall and balanced
accuracy count abstention as failure to recognize the actual class. Accuracy among
classified examples is separate and cannot hide discarded difficult cases.
Unknown-label groups remain in the coverage denominator. Each later session has
its own report; the observed min/max session balanced accuracy is not a confidence
bound for future sessions.

Class recall also has a conditional 95% Wilson interval, using the
[NIST score-interval formulation](https://www.itl.nist.gov/div898/handbook/prc/section2/prc241.htm).
Its independence assumption is serialized. Within-person and within-session
correlation can invalidate that assumption. These intervals are descriptive and
are not activation gates, population estimates, or independent-voice confidence
intervals. Frames, overlapping excerpts and repeated acquisitions are not new
voices. Undefined class/session evidence remains absent rather than imputed.

## Runtime and validation boundaries

Fitting, canonical serialization, hashing, analysis summaries and observation
construction belong on a worker/control path. They allocate and are not audio
callback operations. The dataset limits remain 512 takes across 32 sessions.
An activated target contains the frozen rule, policy, scope and provenance identities;
it retains no PCM, dataset or per-take history. Encoding is bounded to 64 KiB.
Prediction performs no fitting and cannot activate an unevaluated candidate.

The separate [public-API example](../Examples/PersonalTargetWorkflow/README.md) and
`Tools/PersonalTargets/evidence.py` retain independent result audits and repeated
Release timing/RSS evidence at those count limits. Their generated labels and
summaries are synthetic software scenarios. Exact-profile PCM validation is a
separate required step; no real listening or physical-device outcome is implied.

The observation statistic is `selectedIntervalLowerMedianV1`. An instantaneous
live frame is not that statistic. The example validated profile uses whole-interval,
noncausal CPPS at 16 kHz, the pinned Praat 7 Murton recipe, FFT YIN at 50–700 Hz,
and unweighted 400-sample/160-hop level windows. Its full schedule identity is
`c9fbb8420ee5ac5f76254129d42d10358dd393f868a5173ee7dea45e0ce9b01b`.
This evidence does not validate a streaming-preview CPPS profile or another hop,
window, backend or resampling configuration. The
[feedback policy](PersonalTargetFeedback.md) preserves the complete-summary semantics,
exact profile and accepted model while adding source-time persistence and explicit
unavailable states. Model import/export belongs to [#58](https://github.com/plx/hdxl-voice-processing/issues/58);
these types expose encoding and inspection but no permissive model decoder.

The numerical suite compares actual PCM with pinned external CPPS references and
independent Python F0/level calculations, including empty/short/full boundaries and
three alternate chunk layouts at large acquisition offsets. Independent fitting
fixtures cover separation, inverted direction, overlap, both-sided usual values,
outliers, failed holdouts and context confounds. Their labels and measurement
summaries are fabricated software inputs, explicitly distinct from DSP evidence or
human listening. Physical and real-session evidence remains follow-up work under
[#74](https://github.com/plx/hdxl-voice-processing/issues/74) and
[#102](https://github.com/plx/hdxl-voice-processing/issues/102).

Reports can include private listening labels, prompts and recording conditions.
Keep them with their calibration dataset; do not publish private reports as CI
artifacts. Repository evidence uses only identified synthetic inputs.
