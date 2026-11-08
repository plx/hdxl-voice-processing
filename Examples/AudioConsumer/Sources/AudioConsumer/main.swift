import HDXLVoiceProcessingAudio

// Link and exercise the capture product without importing a visualization product,
// requesting authorization, inspecting devices, or constructing a capture engine.
let buffering = try CaptureBuffering(
    requestedTapFrames: 512, maximumFramesPerChunk: 4096, slotCount: 8)
precondition(buffering.requestedTapFrames == 512)
precondition(buffering.maximumFramesPerChunk == 4096)
precondition(buffering.slotCount == 8)
print("Capture buffering metadata: 512 requested frames, 4096-frame capacity, 8 slots")
