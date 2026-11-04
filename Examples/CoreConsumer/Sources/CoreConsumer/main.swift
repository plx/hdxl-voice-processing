import HDXLVoiceProcessing

let source = try PCMFormat(sampleRate: 48_000, channelCount: 1)
print("PCM: \(source.sampleRate) Hz, \(source.channelCount) channel(s)")
