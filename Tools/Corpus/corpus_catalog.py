"""Pinned public source selection and original, sample-exact engineering recipes.

Task labels describe the elicitation protocol, not a voiced-region ground truth.
No clinical or demographic labels are imported or inferred.
"""

VERSION = "pvqd3-engineering/v1"
DATASET_URL = "https://data.mendeley.com/datasets/9dz247gnyb/3"
CONSENT_URL = "https://pmc.ncbi.nlm.nih.gov/articles/PMC11193840/"
LICENSE_URL = "https://creativecommons.org/licenses/by/4.0/"
RIGHTS = {
    "license": "CC-BY-4.0",
    "licenseURL": LICENSE_URL,
    "permission": "granted",
    "evidenceURL": DATASET_URL,
    "attribution": "Walden, Patrick R. (2020), Perceptual Voice Qualities Database (PVQD), Mendeley Data, V3, doi:10.17632/9dz247gnyb.3. Supported by The Voice Foundation.",
    "modificationNotice": "Originals are byte-identical. Excerpts and simulated defects are project modifications recorded in each transformation chain; no endorsement is implied.",
    "consent": {
        "status": "documented",
        "evidenceURL": CONSENT_URL,
        "locator": "Study Design and Participants",
        "basis": "The dataset author's coauthored methods report participant consent for public availability of voice samples. The project does not possess private consent forms.",
    },
}
SOURCES = [
    {
        "id": "pvqd3-bl01", "originalFilename": "BL01 ENSS.wav",
        "fileID": "5183cb8f-77ff-418d-a4cc-e2eca48cb6a5",
        "sha256": "c98e50f90453ec26cfe2e61acaf7a166848bfbbb2f4788c6e2f49281cee37e62",
        "byteCount": 2417152, "sampleCount": 1208554,
    },
    {
        "id": "pvqd3-bl02", "originalFilename": "BL02 ENSS.wav",
        "fileID": "73f751bc-10cd-4551-9f07-479e1ef2a8ac",
        "sha256": "a1603f9d04b9c004b4f886c6eee8397d530c8f6a79eea2962f7b096f533b2b3b",
        "byteCount": 2976816, "sampleCount": 1488386,
    },
    {
        "id": "pvqd3-bl03", "originalFilename": "BL03 ENSS.wav",
        "fileID": "7be55d9e-a714-4aaa-a34f-f342c26adbf5",
        "sha256": "989a72597e06da51d6da550812ebcd9f757bb5c1df98e5551015c5cd1ea9206c",
        "byteCount": 2905488, "sampleCount": 1452722,
    },
]

# Integer source sample indices: the seconds below are just readable construction
# constants. No floating-point rounding or automatic speech detector is used by
# reproduction. Intervals intentionally retain a little task-adjacent background.
EXCERPTS = [
    ("bl01-vowel-a", "pvqd3-bl01", 19 * 44100, 2 * 44100, "sustained-vowel-a"),
    ("bl01-vowel-i", "pvqd3-bl01", 23 * 44100, 2 * 44100, "sustained-vowel-i"),
    ("bl01-all-voiced", "pvqd3-bl01", 67 * 4410, 2 * 44100, "scripted-all-voiced"),
    ("bl01-consonant-rich", "pvqd3-bl01", 152 * 4410, 23 * 4410, "scripted-consonant-rich"),
    ("bl02-vowel-a", "pvqd3-bl02", 22 * 44100, 2 * 44100, "sustained-vowel-a"),
    ("bl02-vowel-i", "pvqd3-bl02", 28 * 44100, 2 * 44100, "sustained-vowel-i"),
    ("bl02-all-voiced", "pvqd3-bl02", 73 * 4410, 24 * 4410, "scripted-all-voiced"),
    ("bl02-consonant-rich", "pvqd3-bl02", 172 * 4410, 26 * 4410, "scripted-consonant-rich"),
    ("bl03-vowel-a", "pvqd3-bl03", 23 * 44100, 2 * 44100, "sustained-vowel-a"),
    ("bl03-vowel-i", "pvqd3-bl03", 28 * 44100, 2 * 44100, "sustained-vowel-i"),
    ("bl03-all-voiced", "pvqd3-bl03", 78 * 4410, 22 * 4410, "scripted-all-voiced"),
    ("bl03-consonant-rich", "pvqd3-bl03", 166 * 4410, 24 * 4410, "scripted-consonant-rich"),
]
ANNOTATION = {
    "version": "project-task-boundaries/v1",
    "sourceProtocolURL": DATASET_URL,
    "methodsFileID": "42a3bbc7-9d3b-475c-8696-a35ff95e580b",
    "methodsSHA256": "59892a973c3d262d5939b64196c66b6f6a4d6420df88d31ae85446759d15b16a",
    "method": "Source CAPE-V task protocol/order, on-device Apple SpeechAnalyzer word-time assistance, and signal-support inspection; integer excerpt boundaries selected by the project.",
    "tool": "Apple Speech framework, macOS 27.0.1; system on-device en-US resources, model revision not exposed; not needed for reproduction",
    "uncertainty": "Provisional task annotations, not a human listening audit, phonetic alignment, or sample-wise voicing labels. An all-voiced task can contain pauses, aspiration, or irregular phonation. Vowels follow the source's a/i order. No clinical, demographic, or speaker-identity inference.",
    "attentionIssue": "https://github.com/plx/hdxl-voice-processing/issues/102",
}
DEFECTS = [
    ("low-level", {"kind": "integer-gain", "numerator": 1, "denominator": 256}),
    ("noisy", {"kind": "integer-noise", "seed": 2701, "amplitudeLSB": 2048}),
    ("clipped", {"kind": "integer-gain", "numerator": 16, "denominator": 1}),
    ("dropout", {"kind": "replace-with-zero", "startSample": 22050, "sampleCount": 8820}),
    ("silence", {"kind": "replace-with-zero", "startSample": 0, "sampleCount": 88200}),
    ("stereo", {"kind": "duplicate-channel"}),
    ("empty", {"kind": "empty-payload"}),
    ("truncated", {"kind": "truncate-file", "removeBytes": 7}),
    ("nonfinite", {"kind": "float32-nan", "sampleIndex": 123}),
]


def recipes():
    result = []
    for name, source, start, count, task in EXCERPTS:
        result.append({
            "id": "corpus-" + name, "sourceID": source, "task": task,
            "condition": "unmodified-excerpt",
            "steps": [{"kind": "excerpt", "startSample": start, "sampleCount": count}],
        })
    base = result[0]
    for condition, step in DEFECTS:
        result.append({
            "id": "corpus-bl01-" + condition, "sourceID": base["sourceID"],
            "task": base["task"], "condition": "simulated-" + condition,
            "steps": [dict(base["steps"][0]), dict(step)],
        })
    return result


SUBSETS = {
    "corpus-smoke/v1": ["corpus-bl01-vowel-a", "corpus-bl01-all-voiced"],
    "corpus-batch/v1": ["corpus-" + item[0] for item in EXCERPTS],
    "corpus-difficult/v1": ["corpus-bl01-" + item[0] for item in DEFECTS],
    # Tiling is explicitly synthetic and each join is a continuity boundary.
    "corpus-long-stream/v1": ["corpus-bl01-all-voiced"],
}
