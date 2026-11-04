import HDXLVoiceProcessing
import Testing

@Test func preservesSourceFormat() throws {
    let format = try PCMFormat(sampleRate: 48_000, channelCount: 2)
    #expect(format.sampleRate == 48_000)
    #expect(format.channelCount == 2)
}

@Test(arguments: [0.0, -1.0, Double.infinity, -Double.infinity, Double.nan])
func rejectsInvalidSampleRates(rate: Double) {
    #expect(throws: PCMFormat.ValidationError.invalidSampleRate) {
        try PCMFormat(sampleRate: rate, channelCount: 1)
    }
}

@Test(arguments: [0, -1, Int.min])
func rejectsInvalidChannelCounts(count: Int) {
    #expect(throws: PCMFormat.ValidationError.invalidChannelCount) {
        try PCMFormat(sampleRate: 48_000, channelCount: count)
    }
}

@Test func sourceFormatCanCrossTaskBoundaries() async throws {
    let source = try PCMFormat(sampleRate: 44_100, channelCount: 1)
    let received = await Task.detached { source }.value
    #expect(source == received)
}
