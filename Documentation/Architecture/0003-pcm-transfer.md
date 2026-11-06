# ADR 0003: Bounded PCM ownership between capture and a worker

Status: accepted for MVP in #23; owner attention #121. Physical evidence remains #74.

## Storage and time

`PCMTransfer` belongs to the Audio product and uses Swift `Synchronization` atomics,
with no external runtime dependency. Prepare it off the capture thread. Configuration
fixes actual sample rate, encoding, layout, source channel identifiers and configuration
epoch. Channel identifiers describe storage order; no callback mixes, interleaves,
resamples, conditions or analyzes samples. Float32 and Float64 use native-endian bytes.

The limits are 65,536 frames/chunk, 32 channels, 4,096 power-of-two slots and 64 MiB PCM
storage. Defaults are 2,048 frames/chunk and 16 slots. All PCM storage is allocated and
touched during initialization. Metadata and state have fixed allocations too. Capacity
counts chunks, including short chunks; memory cannot grow with a slow worker or UI.
The adapter caches `configuration.captureToken` before capture; callbacks pass this
fixed integer token instead of constructing or copying resilient Core/SDK epoch values.
Slot metadata and pending gaps contain only fixed-layout scalar storage. Public epochs
are attached to events on the worker. Source buffers must be valid readable, correctly sized, nonaliasing borrowed memory
for the offer's duration. A successful offer copies before returning. Planar descriptors
must also be prepared before capture; each plane is packed without padding in the slot.

Each nonempty, matching-epoch admitted offer receives a sequence, including rejected
oversized/invalid/capacity offers. Zero-frame callbacks are ignored; epoch mismatches do
not consume a sequence. Source positions are nonnegative sample-frame offsets in the
configured epoch, independent of the ring cursor and worker completion time. Host anchors
are optional monotonic **nanoseconds**, never raw mach ticks. The adapter converts valid
host timestamps using a conversion prepared before capture. Unknown timestamps stay nil.

No format mutation occurs inside a live transport. A controller prepares a replacement
for a new format/epoch and closes/drains the old one. The scheduler (#40) forwards the
boundary, advances its analysis continuity epoch and rebases analysis positions to zero
as required by ADR 0002. It retains the original source positions for measurement timing.
The raw transport does not pretend a capture epoch and an analysis continuity epoch are
interchangeable, nor does it perform the scheduler's frame/history work.

## Loss and overflow

Full capacity drops the whole newest buffer; oversized buffers are also dropped whole,
with no allocation, truncation or unbounded splitting. Invalid sizes/layout/positions
and configuration mismatches are explicit rejections. Lost PCM is never replaced with
silence. A pending gap is attached to the next accepted chunk and delivered as a separate
event **before** that chunk. On close, an otherwise unreported tail gap precedes finished.
While open and no later chunk arrives, counters expose losses immediately; a pending
gap becomes consumable with the next chunk or closure.

Forward source-position jumps report the exact missing interval; backwards/overlapping
positions report unknown loss. Adjacent losses coalesce in constant space. Noncontiguous
or untrustworthy intervals coalesce to nil, preserving the union of reasons. Nil means
unknown, not zero. Consumers must reset overlap/history on every gap, including unknown
ones, and must never concatenate pre-gap and post-gap PCM into one analysis window.

Diagnostics are atomic snapshots off the callback. They count admitted callbacks,
accepted chunks, overflow/oversized/invalid chunks, advertised dropped sample frames,
depth and producer-observed high water. Counters saturate; they do not wrap to zero.
Dropped frames include rejected input and unread PCM discarded after a producer fault;
they exclude inferred source-clock jumps and offers made after closure. A concurrent
producer rejection has unknown temporal extent and is identified by a persistent fault
flag, not a fabricated exact dropped-frame count. Snapshot fields are independently
sampled. Depth uses three bounded attempts and may be nil under continuous contention.

## Ownership, admission and memory ordering

The producer contract is one nonoverlapping producer, including reentrancy. Each attempt
first registers in the upper 61 bits of a UInt64 control word with one native atomic add.
The low bits hold active, closed and violation flags. An already-closed attempt returns
closed; otherwise one strong compare-exchange admits the sole registered caller and
sets active. Failure never spins or waits. An overlapping producer permanently sets
closed plus violation and returns concurrentProducer. Every attempt unregisters with
one release subtraction, after any fault publication; an admitted producer also releases
active without clearing the other bits. The counter cannot wrap with the number of
simultaneous synchronous call frames addressable in a supported 64-bit process.

Registration includes rejected producers: if one is descheduled between failed admission
and fault publication, close/drain must still observe an outstanding participant. Merely
tracking the admitted producer permits a fault to arrive after finished. Consumers wait
for all registered attempts to leave by returning empty, not by blocking. They then discard unread PCM and
emit an unknown producer-violation gap; they do not claim ordering for these samples.
An already borrowed block can finish before the fault is observed. Native adapters
#28/#29 must prove the precondition or supply their own reviewed bounded adaptation.

The single worker also has a one-attempt admission guard. Concurrent/reentrant reads
return concurrentConsumer without advancing cursors. During a borrowed block closure,
the producer cannot reclaim its slot. A slow consumer produces drops, never producer
backpressure. No worker/UI callback is reachable from the producer path.

Producer release-publishes the head only after writing all bytes and metadata; consumer
acquire-loads it before reading. Consumer release-publishes the tail after its borrow
ends; producer acquire-loads it before reuse. Ring arithmetic uses wrapping UInt64 cursors
and a power-of-two capacity well below half the sequence space. Producer and consumer
private mutable state each have a separately owned stable allocation, so synchronization
does not straddle an overlapping Swift inout access. Diagnostics use separate atomics.

Close atomically sets the closed bit and returns without waiting or freeing. Combined
closed/quiescent observation is essential: separate booleans could observe stale idle
state while an admitted producer is writing or a rejected producer owes a fault report.
After acquiring closed with no active or registered participants, the
consumer reloads the published cursor before deciding that the queue is empty, and can
safely read final pending producer state. No subsequent producer can gain admission or
publish a new fault. Finished is sticky on the consumer; later already-closed offers
cannot temporarily make it empty again while registering and unregistering.

The controller retains the object until native callbacks are quiescent and worker calls
have returned. Final release belongs on a control/worker thread. Close is **not** a native
callback cancellation acknowledgment. Strong ownership keeps storage alive through every
method and borrow; destruction never occurs inside close. A callback must not be the
last owner. The adapter lifecycle tests in #28/#29 must exercise this responsibility.

## Evidence and limitations

Swift's atomics guarantee lock-freedom, not general wait-freedom. For the pinned Swift
6.4/SDK 27 toolchain, isolated admission, closure, publication and counter probes compile
to native atomic instructions on macOS arm64, iOS arm64 and iOS simulator x86_64, without
software retry loops. Full transport source/optimized-code audit, allocation capability
controls and synthetic stress belong to #23's merge gate. These do not guarantee scheduling
latency, residency, power behavior or native callback serialization on physical devices.
Track hardware measurements in #74 and capacity-policy review in #121.

Primary references:

- [Swift SE-0410 atomics](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0410-atomics.md)
- [Swift SE-0282 memory model and exclusivity](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0282-atomics.md)
- [Apple tap installation](https://developer.apple.com/documentation/avfaudio/avaudionode/installtap(onbus:buffersize:format:block:)) permits buffer sizes different from the request and does not document serialization.
- [Apple AVAudioTime](https://developer.apple.com/documentation/avfaudio/avaudiotime) distinguishes optional source-sample and host-clock representations.
