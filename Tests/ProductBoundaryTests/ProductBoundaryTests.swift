// These imports compile and link the optional products together. They must not
// trigger capture, authorization, or UI lifecycle work during module loading.
import HDXLVoiceProcessing
import HDXLVoiceProcessingAudio
import HDXLVoiceProcessingVisualization
import Testing

@Test func optionalProductsAcceptCoreValues() throws {
    let source = try PCMFormat(sampleRate: 48_000, channelCount: 1)
    #expect(source.channelCount == 1)
}
