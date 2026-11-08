import AVFAudio
import Foundation
import HDXLVoiceProcessing

/// Single-owner file decoder feeding the same prepared numerical engine as live
/// PCM. Reads are bounded and synchronous. Prepare on a worker/control path; never
/// call from capture. A new file or seek gets an independent prepared instance.
public final class PreparedAudioFileSchedule<Sample: BinaryFloatingPoint & Sendable> {
    public let profile: AnalysisScheduleProfile
    public let origin: AnalysisScheduleOrigin
    public let source: SourceInterval
    public let decoding: AudioFileDecodingProvenance
    public let chunkCapacity: Int
    /// Decoder position corresponding to origin.source.startSample. The default
    /// keeps legacy file-coordinate behavior; an explicit mapping preserves live
    /// source clocks when a stored recording starts at a different file frame.
    public let fileStartSample: Int64
    public let mask: PreparedAnalysisMask?
    public let maskRouting: AudioFileMaskRouting
    public private(set) var nextSourceSample: Int64
    public private(set) var completion: AudioFileScheduleCompletion?
    public var isCancelled: Bool { state == .cancelled }

    private enum State { case prepared, finished, cancelled, failed }
    private var state = State.prepared
    private var busy = false
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    private let plain: PreparedAnalysisSchedule<Sample>?
    private let masked: PreparedMaskedAnalysisSchedule<Sample>?
    private var planes: UnsafeMutableBufferPointer<UnsafeBufferPointer<Sample>>
    private var eligibleRegionIndex = 0

    /// Owned PCM/descriptor/core scratch. The system decoder's opaque codec buffers
    /// are outside this count and outside the core scheduler allocation guarantee.
    public var preparedBufferBytes: Int {
        (plain?.preparedBufferBytes ?? 0) + (masked?.preparedBufferBytes ?? 0)
            + chunkCapacity * profile.inputFormat.channelCount * MemoryLayout<Sample>.stride
            + planes.count * MemoryLayout<UnsafeBufferPointer<Sample>>.stride
    }

    public init(
        url: URL, profile: AnalysisScheduleProfile, origin: AnalysisScheduleOrigin,
        fileStartSample: Int64? = nil,
        sampleCount: Int64? = nil, chunkCapacity: Int = 2048, sourceTileCapacity: Int = 256,
        mask: PreparedAnalysisMask? = nil, maskRouting: AudioFileMaskRouting = .splitAtRegions
    ) throws {
        guard (1...65536).contains(chunkCapacity) else {
            throw AudioFileScheduleError.invalidCapacity
        }
        guard
            (Sample.self == Float.self && profile.inputPrecision == .float32)
                || (Sample.self == Double.self && profile.inputPrecision == .float64)
        else { throw AnalysisScheduleError.precisionMismatch }
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: profile.inputPrecision == .float32
                ? .pcmFormatFloat32 : .pcmFormatFloat64,
            interleaved: profile.inputFormat.layout == .interleaved)
        let format = file.processingFormat
        guard format.sampleRate == profile.inputFormat.sampleRate,
            Int(format.channelCount) == profile.inputFormat.channelCount,
            format.isInterleaved == (profile.inputFormat.layout == .interleaved)
        else { throw AudioFileScheduleError.formatMismatch }
        let length = file.length
        let fileStart = fileStartSample ?? origin.source.startSample
        guard length >= 0, fileStart >= 0, fileStart <= length else {
            throw AudioFileScheduleError.invalidRange
        }
        let count = sampleCount ?? (length - fileStart)
        guard count >= 0, count <= length - fileStart else {
            throw AudioFileScheduleError.invalidRange
        }
        let source = try SourceInterval(
            epoch: origin.source.epoch,
            startSample: origin.source.startSample, sampleCount: count,
            sampleRate: origin.source.sampleRate)
        if let mask, maskRouting == .splitAtRegions {
            guard mask.timeline.plan.source == source else {
                throw AudioFileScheduleError.invalidRange
            }
        }
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkCapacity))
        else { throw AudioFileScheduleError.invalidCapacity }
        self.profile = profile
        self.origin = origin
        self.source = source
        self.chunkCapacity = chunkCapacity
        self.fileStartSample = fileStart
        self.mask = mask
        self.maskRouting = maskRouting
        self.nextSourceSample = source.startSample
        self.file = file
        self.buffer = buffer
        self.decoding = AudioFileDecodingProvenance(
            url: url, storage: AudioFileStorageFormat(file.fileFormat),
            decodedPCM: profile.inputFormat, fileSampleCount: length,
            decoderIdentifier: "apple-avaudiofile-native-pcm-v1",
            platformVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        if let mask, maskRouting == .splitAtRegions {
            plain = nil
            masked = try PreparedMaskedAnalysisSchedule(
                profile: profile, origin: origin,
                mode: .finite, mask: mask, sourceTileCapacity: sourceTileCapacity)
        } else {
            masked = nil
            plain = try PreparedAnalysisSchedule(
                profile: profile, origin: origin,
                mode: .finite, expectedSampleCount: count, sourceTileCapacity: sourceTileCapacity,
                mask: mask)
        }
        planes = .allocate(capacity: profile.inputFormat.channelCount)
        planes.initialize(repeating: UnsafeBufferPointer(start: nil, count: 0))
        file.framePosition = fileStart
    }

    deinit {
        planes.deinitialize()
        planes.deallocate()
        file.close()
    }

    @discardableResult public func read(
        maximumChunks: Int = 1, emit: (AudioFileScheduledFrame) -> Void,
        regionCompleted: (AnalysisScheduleCompletion) -> Void = { _ in }
    ) throws -> AudioFileScheduleProgress {
        guard !busy else { throw AnalysisScheduleError.reentrantCall }
        guard (1...4096).contains(maximumChunks) else {
            throw AudioFileScheduleError.invalidCapacity
        }
        guard state != .failed else { throw AnalysisScheduleError.invalidState }
        guard state == .prepared else {
            return AudioFileScheduleProgress(
                decodedSampleCount: 0, advancedSourceSamples: 0,
                isFinished: state == .finished, isCancelled: isCancelled)
        }
        busy = true
        let start = nextSourceSample
        var decoded: Int64 = 0
        defer {
            busy = false
            for index in planes.indices {
                planes[index] = UnsafeBufferPointer(start: nil, count: 0)
            }
            if isCancelled { file.close() }
        }
        do {
            for _ in 0..<maximumChunks
            where state == .prepared && nextSourceSample < source.endSample {
                var end = source.endSample
                if let mask, let masked {
                    let regions = mask.timeline.eligibleRegions
                    while eligibleRegionIndex < regions.count,
                        regions[eligibleRegionIndex].endSample <= nextSourceSample
                    { eligibleRegionIndex += 1 }
                    let next =
                        eligibleRegionIndex < regions.count
                        ? regions[eligibleRegionIndex].startSample : source.endSample
                    if nextSourceSample < next {
                        try masked.skipMissingAcquisition(
                            interval(start: nextSourceSample, end: next))
                        nextSourceSample = next
                        file.framePosition = fileStartSample + (next - source.startSample)
                    }
                    if nextSourceSample == source.endSample { break }
                    end = regions[eligibleRegionIndex].endSample
                }
                // OS 27 reports reading beyond EOF as an error; never request a
                // capacity-sized read when fewer declared source frames remain.
                let request = min(chunkCapacity, Int(end - nextSourceSample))
                try file.read(into: buffer, frameCount: AVAudioFrameCount(request))
                let count = Int(buffer.frameLength)
                guard count > 0, count <= request else {
                    throw AudioFileScheduleError.unexpectedEndOfFile
                }
                let part = try interval(
                    start: nextSourceSample, end: nextSourceSample + Int64(count))
                let report = try processBuffer(
                    interval: part, emit: emit, regionCompleted: regionCompleted)
                decoded += Int64(count)
                nextSourceSample += Int64(report.consumedSourceSamples)
            }
            if state == .prepared, nextSourceSample == source.endSample {
                if let plain {
                    let result = try plain.finish { deliver($0, emit: emit) }
                    if state == .prepared {
                        completion = .analyzed(result)
                        regionCompleted(result)
                    }
                } else if let masked {
                    completion = .masked(try masked.finish())
                }
                if state == .prepared {
                    state = .finished
                    file.close()
                }
            }
            if isCancelled { try recordCancellation() }
            return AudioFileScheduleProgress(
                decodedSampleCount: decoded,
                advancedSourceSamples: nextSourceSample - start,
                isFinished: state == .finished, isCancelled: isCancelled)
        } catch {
            if state != .cancelled { state = .failed }
            file.close()
            throw error
        }
    }

    private func processBuffer(
        interval: SourceInterval, emit: (AudioFileScheduledFrame) -> Void,
        regionCompleted: (AnalysisScheduleCompletion) -> Void
    ) throws -> AnalysisScheduleProcessReport {
        let count = Int(buffer.frameLength)
        let channels = profile.inputFormat.channelCount
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        if profile.inputFormat.layout == .interleaved {
            guard buffers.count == 1, Int(buffers[0].mNumberChannels) == channels,
                Int(buffers[0].mDataByteSize) >= count * channels * MemoryLayout<Sample>.stride,
                let data = buffers[0].mData
            else { throw AudioFileScheduleError.invalidDecodedBuffer }
            let input = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Sample.self), count: count * channels)
            if let plain {
                return try plain.processInterleaved(input, interval: interval) {
                    deliver($0, emit: emit)
                }
            }
            return try masked!.processInterleaved(
                input, interval: interval,
                emit: { deliver($0, emit: emit) }, regionCompleted: regionCompleted)
        }
        guard buffers.count == channels else { throw AudioFileScheduleError.invalidDecodedBuffer }
        for channel in 0..<channels {
            guard buffers[channel].mNumberChannels == 1,
                Int(buffers[channel].mDataByteSize) >= count * MemoryLayout<Sample>.stride,
                let data = buffers[channel].mData
            else { throw AudioFileScheduleError.invalidDecodedBuffer }
            planes[channel] = UnsafeBufferPointer(
                start: data.assumingMemoryBound(to: Sample.self), count: count)
        }
        if let plain {
            return try plain.processPlanar(UnsafeBufferPointer(planes), interval: interval) {
                deliver($0, emit: emit)
            }
        }
        return try masked!.processPlanar(
            UnsafeBufferPointer(planes), interval: interval,
            emit: { deliver($0, emit: emit) }, regionCompleted: regionCompleted)
    }

    private func deliver(_ frame: ScheduledFrame, emit: (AudioFileScheduledFrame) -> Void) {
        guard state == .prepared else { return }
        emit(AudioFileScheduledFrame(frame: frame, decoding: decoding))
    }

    private func interval(start: Int64, end: Int64) throws -> SourceInterval {
        try SourceInterval(
            epoch: source.epoch, startSample: start,
            sampleCount: end - start, sampleRate: source.sampleRate)
    }

    private func recordCancellation() throws {
        let observed = try interval(start: source.startSample, end: nextSourceSample)
        let coverage: AnalysisCoverageCounts
        if let mask {
            coverage = try mask.coverage(of: observed)
        } else {
            coverage = .acquired(observed.sampleCount)
        }
        completion = .cancelled(source: observed, coverage: coverage)
    }

    /// Cooperative, including from emit. File closure occurs after active reads
    /// and borrowed buffers return. Other batch inputs use independent instances.
    public func cancel() {
        state = .cancelled
        completion = nil
        plain?.cancel()
        masked?.cancel()
        if !busy {
            file.close()
            // SourceInterval and prepared coverage already bound this exact prefix.
            try? recordCancellation()
        }
    }
}
