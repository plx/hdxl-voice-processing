/// Source-relative seconds before the explicit sample-boundary quantization.
/// This preserves the external reference's interval decisions for diagnostics.
public struct SpeechActivityInterval: Sendable, Hashable, Encodable {
    public internal(set) var startSeconds: Double
    public internal(set) var endSeconds: Double
    public internal(set) var isSpeech: Bool
}

/// Prepared in-place interval compaction. Removing a short interior interval
/// extends the previous interval; removing the first extends the next. Each
/// pass is linear in the interval count, including dense transition workloads.
final class ActivityIntervalBuffer {
    let storage: UnsafeMutableBufferPointer<SpeechActivityInterval>
    var count = 0
    var values: UnsafeBufferPointer<SpeechActivityInterval> {
        UnsafeBufferPointer(start: storage.baseAddress, count: count)
    }
    init(capacity: Int) {
        storage = .allocate(capacity: max(1, capacity))
        storage.initialize(
            repeating: SpeechActivityInterval(startSeconds: 0, endSeconds: 0, isSpeech: false))
    }
    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    func build(layout: LTSFIntervalLayout, label: (Int) -> Bool) throws {
        count = 0
        guard layout.frameCount > 0 else { return }
        var start = 0.0
        var previous = label(0)
        for index in 1..<layout.frameCount {
            let current = label(index)
            if current != previous {
                let end = try layout.centerSeconds(frameIndex: index)
                try append(start: start, end: end, speech: previous)
                start = end
                previous = current
            }
        }
        try append(start: start, end: layout.source.durationSeconds, speech: previous)
    }

    func append(start: Double, end: Double, speech: Bool) throws {
        guard count < storage.count else { throw MaskError.capacityExceeded }
        guard start.isFinite, end.isFinite, start < end else { throw MaskError.invalidObservation }
        storage[count] = SpeechActivityInterval(
            startSeconds: start, endSeconds: end, isSpeech: speech)
        count += 1
    }

    func clean(minimumSpeech: Double, minimumNonSpeech: Double) {
        removeShort(speech: true, minimum: minimumSpeech)
        combine(speech: false)
        removeShort(speech: false, minimum: minimumNonSpeech)
        combine(speech: true)
    }

    private func removeShort(speech: Bool, minimum: Double) {
        var written = 0
        var pendingStart: Double?
        for index in 0..<count {
            var current = storage[index]
            if let pendingStart { current.startSeconds = pendingStart }
            pendingStart = nil
            if current.isSpeech == speech, current.endSeconds - current.startSeconds < minimum,
                !(written == 0 && index == count - 1)
            {
                if written == 0 {
                    pendingStart = current.startSeconds
                } else {
                    storage[written - 1].endSeconds = current.endSeconds
                }
            } else {
                storage[written] = current
                written += 1
            }
        }
        count = written
    }

    func combine(speech: Bool) {
        var written = 0
        for index in 0..<count {
            let current = storage[index]
            if written > 0, current.isSpeech == speech, storage[written - 1].isSpeech == speech {
                storage[written - 1].endSeconds = current.endSeconds
            } else {
                storage[written] = current
                written += 1
            }
        }
        count = written
    }

    /// The pinned combination's 20 ms end margin is explicit. It can retain the
    /// current activity label to an intensity interval's end; it is not a plain
    /// set intersection. Inputs are complete partitions with shared duration.
    func combine(spectral: ActivityIntervalBuffer, intensity: ActivityIntervalBuffer) throws {
        count = 0
        var spectralIndex = 0
        for energy in intensity.values {
            if !energy.isSpeech {
                try append(start: energy.startSeconds, end: energy.endSeconds, speech: false)
                continue
            }
            while spectralIndex < spectral.count,
                spectral.storage[spectralIndex].endSeconds <= energy.startSeconds
            {
                spectralIndex += 1
            }
            var start = energy.startSeconds
            while start < energy.endSeconds {
                guard spectralIndex < spectral.count else { throw MaskError.invalidObservation }
                let activity = spectral.storage[spectralIndex]
                let end =
                    activity.endSeconds > energy.endSeconds - 0.02
                    ? energy.endSeconds : activity.endSeconds
                try append(start: start, end: end, speech: activity.isSpeech)
                start = end
                if end < energy.endSeconds { spectralIndex += 1 }
            }
        }
        combine(speech: false)
    }
}

/// Exact quadratic vertex height for each eligible local maximum, including the
/// two endpoint values. Used only as a relative intensity reference, never SPL.
func interpolatedIntensityMaximum(_ values: UnsafeBufferPointer<Double>) -> Double {
    precondition(!values.isEmpty)
    var maximum = max(values[0], values[values.count - 1])
    if values.count > 2 {
        for index in 1..<(values.count - 1) {
            let left = values[index - 1]
            let middle = values[index]
            let right = values[index + 1]
            if middle > left && middle >= right {
                let firstDerivative = (right - left) / 2
                let negativeCurvature = 2 * middle - left - right
                let peak = middle + 0.5 * firstDerivative * firstDerivative / negativeCurvature
                maximum = max(maximum, peak)
            }
        }
    }
    return maximum
}
