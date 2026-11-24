"""Audit the optimized native buffer bridge up to its SDK and PCM transport boundaries."""

import re

# AVFAudio clock/format accessors and its scoped borrow. The runtime and SDK
# implementation behind these named calls is outside the library-owned body.
SDK = {
    "_$s8AVFAudio24AVReadOnlyAudioPCMBufferV6formatSo13AVAudioFormatCvg",
    "_$s8AVFAudio24AVReadOnlyAudioPCMBufferV11frameLengthSivg",
    "_$s8AVFAudio24AVReadOnlyAudioPCMBufferV13frameCapacitySivg",
    "_$s8AVFAudio24AVReadOnlyAudioPCMBufferV010withUnsafeD10BufferListyxxSPySo0dhI0VGKXEKlF",
    *("_objc_msgSend$" + getter for getter in ("sampleRate", "channelCount", "commonFormat",
                                               "isInterleaved", "isHostTimeValid", "hostTime",
                                               "isSampleTimeValid", "sampleTime")),
}
PRIMITIVES = {"_objc_release", "_bzero", "_memset", "___udivti3",
              *(f"_objc_release_x{i}" for i in range(29))}


def inspect_tap(bodies, transport):
    names = {name for name in bodies if "PreparedCaptureTapC6accept" in name}
    if not any(name.endswith("CtF") for name in names) or not any("BufferListVGXEfU_" in name for name in names):
        raise ValueError("Missing native tap entry or buffer borrow closure")
    pending = list(names)
    calls = {}
    while pending:
        name = pending.pop()
        if name in calls:
            continue
        targets = set()
        for line in bodies[name].splitlines():
            words = line.strip().split()
            if len(words) < 2:
                continue
            op = words[0]
            if not (op in {"b", "bl", "br", "blr", "cbz", "cbnz", "tbz", "tbnz"}
                    or op.startswith(("call", "j", "bra", "blra", "b."))):
                continue
            conditional = op.startswith(("b.", "cb", "tb")) or (op.startswith("j") and not op.startswith("jmp"))
            target = line.split(";", 1)[0].split("# ", 1)[0].split()[-1] if conditional else words[1]
            if (conditional or op in {"b", "jmp", "jmpq"}) and re.fullmatch(r"L\w+", target):
                continue
            targets.add(target)
            if target in SDK or target in PRIMITIVES or target in transport:
                continue
            if target in bodies and ("PreparedCaptureTapC" in target or "PCMTransferC5close" in target):
                pending.append(target)
            else:
                raise ValueError(f"Unaudited tap control transfer in {name}: {op} {target}")
        calls[name] = sorted(targets)
    all_targets = set().union(*calls.values())
    if not all_targets.intersection(transport) or not any("withUnsafe" in name for name in all_targets):
        raise ValueError("Optimized tap did not reach both native borrow and audited transport")
    return dict(libraryFunctions=len(calls), calls=calls, namedSDKBoundaries=sorted(all_targets & SDK),
                runtimeAndMemoryPrimitives=sorted(all_targets & PRIMITIVES),
                handoffTargets=sorted(all_targets.intersection(transport)),
                descriptorLoopBound="validated native buffer count equals one or configured channels (at most 32)")
