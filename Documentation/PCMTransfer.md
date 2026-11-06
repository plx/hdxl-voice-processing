# Capture-to-worker PCM transfer

`HDXLVoiceProcessingAudio.PCMTransfer` copies native floating-point capture buffers
into a fixed-capacity queue. Prepare it before capture; use one nonoverlapping producer
and one serial consumer. The queue does not start a microphone, request authorization,
schedule tasks, or invoke downstream code from a capture callback.

```swift
import Foundation
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio

let configuration = try PCMTransferConfiguration(
    format: PCMFormat(sampleRate: 48_000, channelCount: 1),
    epoch: StreamEpoch(streamID: UUID()),
    maximumFramesPerChunk: 2048,
    slotCount: 16)
let transfer = PCMTransfer(configuration: configuration)
let captureToken = configuration.captureToken  // Cache before installing the callback.

// The adapter supplies borrowed samples, a source-frame position, and a valid
// host anchor already converted to nanoseconds (or nil when unavailable).
func offerCapturedSamples(
    _ samples: UnsafeBufferPointer<Float>, frameCount: UInt32,
    position: Int64, hostNanoseconds: UInt64?
) -> PCMTransferOfferResult {
    return transfer.offerInterleaved(
        UnsafeRawBufferPointer(samples), frameCount: frameCount,
        sourceStartSample: position, configurationToken: captureToken,
        hostStartNanoseconds: hostNanoseconds)
}
```

That example is mono; the native adapter supplies its reported frame count so malformed
buffer sizes are rejected by the transport with an explicit gap. For interleaved
multichannel input, `frameCount` counts frames,
while the byte buffer contains `frameCount * channelCount` scalar samples. Float64
uses `.float64` in the prepared format and native Double bytes. Planar input uses
`offerPlanar` with one `UnsafeRawBufferPointer` per channel; allocate descriptor
storage before capture and borrow the planes only for the offer. PCM is copied in
the original layout. The immutable `channelMap` identifies the source channels in
storage order. Conversion, mixing, numerical validation and DSP happen on the worker.

Every nonempty offer must carry the prepared token. It identifies the full stream UUID
and epoch sequence without constructing or copying resilient SDK/Core values on the
callback. Do not fetch/copy the full configuration in the callback. Source positions are
nonnegative, epoch-local sample frames; gaps and backwards jumps are detected. Host time
is optional **nanoseconds**, not raw `AVAudioTime.hostTime` ticks. The adapter must prepare
its clock conversion before capture. Unknown time remains nil.

On the serial worker, `withNext` delivers at most one event per call. A `.block` contains
borrowed native bytes, frame count, offer sequence, source start, configuration epoch
and available host anchor. Its bytes are valid only during that closure. For planar
blocks, each channel occupies `frameCount * bytesPerSample` contiguous bytes with no
maximum-chunk padding. Keep the immutable configuration alongside the worker to interpret
the bytes. A `.gap` must reset overlap/history **before** processing the next block.
Known contiguous loss has a half-open source interval; nil means unknown loss. The
scheduler owns translation to a fresh analysis continuity epoch and analysis position zero.

Full queues drop the whole newest chunk. Oversized, malformed and mismatched-epoch
offers are explicit rejections; no partial chunk or fabricated silence is emitted.
Pending gaps coalesce in fixed storage. They are delivered before the next accepted
block, or at final drain if no later block arrives. While the queue stays open without
new PCM, use its off-callback snapshot to observe pending loss counters.

Capacity is in **chunks**, including short chunks. Limits are 65,536 frames/chunk,
32 channels, 2–4,096 power-of-two slots, and 64 MiB total PCM storage. These are MVP
resource limits, not measured optimal defaults; [#121](https://github.com/plx/hdxl-voice-processing/issues/121)
tracks later tuning. Snapshots report admitted callbacks, accepted/rejected chunks,
advertised dropped frames, depth, high water and closure/fault state. Fields are
independently sampled; depth may be nil under sustained concurrent changes.

Overlapping or reentrant producer calls return `.concurrentProducer` and permanently
close admission. After the admitted producer finishes, the worker discards unread PCM
and emits an unknown producer-violation gap. This is an explicit failed precondition,
not an MPSC transport. Each native adapter must demonstrate serialization or implement
a separately audited bounded adaptation. Concurrent/reentrant consumer calls return
`.concurrentConsumer` without changing ownership.

Call `close()` from control or worker code to stop new admission. An admitted producer
can finish its copy. Continue draining until `.finished`, including a possible final
gap; `.empty` can still mean the last producer is active. Close never waits or frees
storage. Retain the transport until native callbacks are quiescent and all worker
borrows finish, then release the final owner off the capture thread. Format changes
prepare a new transport and explicit epoch boundary; an existing transport is immutable.

The [ownership and memory-ordering decision](Architecture/0003-pcm-transfer.md) explains
the atomics, loss semantics and audit boundaries. [Developer evidence tools](../Tools/Transport/README.md)
check optimized callbacks and measured allocation behavior. Synthetic checks do not
replace the deferred [physical-device measurements](https://github.com/plx/hdxl-voice-processing/issues/74).
