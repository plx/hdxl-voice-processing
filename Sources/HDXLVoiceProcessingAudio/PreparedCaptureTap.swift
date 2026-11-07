#if os(macOS)
    import AVFAudio
    import Darwin
    import HDXLVoiceProcessing
    import Synchronization

    /// A terminal tap failure, reported on the control owner by `poll()`.
    public enum CaptureTapFailure: UInt8, Error, Sendable, Hashable {
        case formatChanged = 1
        case invalidBuffer, overlappingCallback, clockOverflow
    }

    /// Prepared native-buffer bridge. No engine, permission, or session operations.
    /// Public so developer probes can measure the exact production callback path.
    ///
    /// Synchronization audit: immutable limits and allocation addresses; an atomic
    /// admission flag protects all mutable descriptors and clock state. Rejected
    /// concurrent callbacks touch only atomics and close the transport. The tap closure
    /// owns this object until its call returns; final release must happen off capture.
    public final class PreparedCaptureTap: @unchecked Sendable {
        public let transfer: PCMTransfer
        private let rate: Double
        private let channels: Int
        private let encoding: AVAudioCommonFormat
        private let interleaved: Bool
        private let width: Int
        private let token: PCMTransferEpochToken
        private let numerator: UInt64
        private let denominator: UInt64
        private let active = Atomic<Bool>(false)
        private let closed = Atomic<Bool>(false)
        private let failureCode = Atomic<UInt8>(0)
        private let planes: UnsafeMutableBufferPointer<UnsafeRawBufferPointer>
        private var nextSample: Int64 = 0
        private var expectedDeviceSample: Int64?
        private var received = false

        public init(transfer: PCMTransfer) {
            self.transfer = transfer
            let configuration = transfer.configuration
            rate = configuration.format.sampleRate
            channels = configuration.format.channelCount
            encoding =
                configuration.format.encoding == .float32 ? .pcmFormatFloat32 : .pcmFormatFloat64
            interleaved = configuration.format.layout == .interleaved
            width = configuration.bytesPerSample
            token = configuration.captureToken
            planes = .allocate(capacity: channels)
            planes.initialize(repeating: UnsafeRawBufferPointer(start: nil, count: 0))
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            numerator = UInt64(timebase.numer)
            denominator = UInt64(timebase.denom)
        }

        deinit {
            planes.deinitialize()
            planes.deallocate()
        }

        public var failure: CaptureTapFailure? {
            CaptureTapFailure(rawValue: failureCode.load(ordering: .acquiring))
        }

        private func fail(_ reason: CaptureTapFailure) {
            _ = failureCode.compareExchange(
                expected: 0, desired: reason.rawValue, ordering: .releasing)
            close()
        }

        /// Stops admission without waiting for a callback already in flight.
        public func close() {
            closed.store(true, ordering: .releasing)
            transfer.close()
        }

        /// Copies borrowed samples before returning. Never retains the buffer or its
        /// pointers. Oversized/full transfers use the transport's explicit drop policy.
        @inline(never)
        public func accept(_ buffer: AVReadOnlyAudioPCMBuffer, at time: AVAudioTime) {
            guard !closed.load(ordering: .acquiring) else { return }
            guard
                active.compareExchange(expected: false, desired: true, ordering: .acquiring)
                    .exchanged
            else {
                fail(.overlappingCallback)
                return
            }
            defer { active.store(false, ordering: .releasing) }
            guard !closed.load(ordering: .acquiring) else { return }
            let format = buffer.format
            guard format.sampleRate == rate, Int(format.channelCount) == channels,
                format.commonFormat == encoding, format.isInterleaved == interleaved
            else {
                fail(.formatChanged)
                return
            }
            guard let frames = UInt32(exactly: buffer.frameLength),
                buffer.frameLength <= buffer.frameCapacity
            else {
                fail(.invalidBuffer)
                return
            }
            if frames == 0 { return }
            let deviceSample =
                time.isSampleTimeValid && time.sampleRate == rate ? time.sampleTime : nil
            var discontinuity = false
            var start = nextSample
            if received {
                switch (expectedDeviceSample, deviceSample) {
                case (.some(let expected), .some(let actual)):
                    let delta = actual.subtractingReportingOverflow(expected)
                    guard !delta.overflow else {
                        fail(.clockOverflow)
                        return
                    }
                    if delta.partialValue > 0 {
                        let advanced = start.addingReportingOverflow(delta.partialValue)
                        guard !advanced.overflow else {
                            fail(.clockOverflow)
                            return
                        }
                        start = advanced.partialValue
                    } else if delta.partialValue < 0 {
                        discontinuity = true
                    }
                case (.none, .none): break
                default: discontinuity = true
                }
            }
            let end = start.addingReportingOverflow(Int64(frames))
            guard !end.overflow else {
                fail(.clockOverflow)
                return
            }
            if let deviceSample {
                let expected = deviceSample.addingReportingOverflow(Int64(frames))
                guard !expected.overflow else {
                    fail(.clockOverflow)
                    return
                }
                expectedDeviceSample = expected.partialValue
            } else {
                expectedDeviceSample = nil
            }
            nextSample = end.partialValue
            received = true
            var host: UInt64?
            if time.isHostTimeValid, denominator > 0 {
                let product = time.hostTime.multipliedFullWidth(by: numerator)
                if product.high < denominator {
                    host = denominator.dividingFullWidth(product).quotient
                }
            }
            buffer.withUnsafeAudioBufferList { list in
                // The SDK guarantees the list extent. Descriptor storage is preallocated.
                let buffers = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: list))
                let planeBytes = Int(frames) * width
                guard buffers.count == (interleaved ? 1 : channels) else {
                    fail(.invalidBuffer)
                    return
                }
                defer {
                    for index in buffers.indices {
                        planes[index] = UnsafeRawBufferPointer(start: nil, count: 0)
                    }
                }
                for index in buffers.indices {
                    let value = buffers[index]
                    let expectedChannels = interleaved ? channels : 1
                    let bytes = planeBytes * expectedChannels
                    guard Int(value.mNumberChannels) == expectedChannels,
                        Int(value.mDataByteSize) >= bytes, value.mData != nil
                    else {
                        fail(.invalidBuffer)
                        return
                    }
                    planes[index] = UnsafeRawBufferPointer(start: value.mData, count: bytes)
                }
                if interleaved {
                    _ = transfer.offerInterleaved(
                        planes[0], frameCount: frames, sourceStartSample: start,
                        configurationToken: token, hostStartNanoseconds: host,
                        deviceSampleTime: deviceSample, sourceDiscontinuity: discontinuity)
                } else {
                    _ = transfer.offerPlanar(
                        UnsafeBufferPointer(planes), frameCount: frames, sourceStartSample: start,
                        configurationToken: token, hostStartNanoseconds: host,
                        deviceSampleTime: deviceSample, sourceDiscontinuity: discontinuity)
                }
            }
        }

        // Deterministic admission/arithmetic seams, unavailable through the public API.
        // Neither installs a callback hook; initialize counters before publication.
        convenience init(transfer: PCMTransfer, initialSourceSample: Int64) {
            self.init(transfer: transfer)
            nextSample = initialSourceSample
        }

        func withHeldAdmissionForTesting(_ body: () -> Void) {
            precondition(
                active.compareExchange(expected: false, desired: true, ordering: .acquiring)
                    .exchanged)
            defer { active.store(false, ordering: .releasing) }
            body()
        }
    }
#endif
