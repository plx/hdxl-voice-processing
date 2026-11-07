#if os(macOS) || (os(iOS) && !targetEnvironment(macCatalyst))
    import Foundation
    import HDXLVoiceProcessing

    /// Owns one capture operation and one serial analysis worker. Construction has
    /// no audio effects. Permission prompts and iOS session grants remain host-owned.
    /// Stop is supported from the event handler; other commands must run on a later
    /// control turn. Await finish before reusing session ownership or accepting cleanup.
    @MainActor public final class CaptureLifecycle {
        public private(set) var state: CaptureLifecycleState = .idle
        public private(set) var configuration: CaptureLifecycleConfiguration?
        private let owner = UUID()
        private var intent: UUID?
        private var controlRevision = UUID()
        private var nextEpoch = StreamEpoch(streamID: UUID())
        private var lastConfiguration: CaptureLifecycleConfiguration?
        private var operation: Operation?
        private var completion: Task<CaptureLifecycleCompletion, Never>?
        private var delivering = false
        private let onEvent: @MainActor (CaptureLifecycleEvent) -> Void
        private let makeDriver:
            (@escaping @MainActor @Sendable (CaptureLifecycleSignal) -> Void) ->
                any CaptureLifecycleDriver
        private let makeWorker: @Sendable () -> any CaptureLifecycleWorking

        @MainActor private final class Operation {
            let generation: UUID
            let epoch: StreamEpoch
            var driver: (any CaptureLifecycleDriver)?
            var worker: (any CaptureLifecycleWorking)?
            var startup: Task<CaptureLifecycleConfiguration, any Error>?
            var pump: Task<Void, Never>?
            var terminal: Task<CaptureLifecycleCompletion, Never>?
            var published = false
            var stopping = false
            var explicitStop = false
            var change = CaptureLifecycleChange.explicitStop
            var primary: CaptureLifecycleFailure?
            var cleanup: CaptureLifecycleFailure?
            var disposition: IOSCaptureSessionDisposition?
            var recoveryIntent: CaptureLifecycleRecoveryIntent?
            init(generation: UUID, epoch: StreamEpoch) {
                self.generation = generation
                self.epoch = epoch
            }
        }

        public convenience init(
            onEvent: @escaping @MainActor (CaptureLifecycleEvent) -> Void = { _ in }
        ) {
            self.init(
                makeDriver: { signal in
                    #if os(macOS)
                        MacOSLifecycleDriver(signal: signal)
                    #else
                        IOSLifecycleDriver(signal: signal)
                    #endif
                }, makeWorker: { CaptureAnalysisWorker() }, onEvent: onEvent)
        }

        init(
            makeDriver:
                @escaping (@escaping @MainActor @Sendable (CaptureLifecycleSignal) -> Void) ->
                any CaptureLifecycleDriver,
            makeWorker: @escaping @Sendable () -> any CaptureLifecycleWorking = {
                CaptureAnalysisWorker()
            },
            onEvent: @escaping @MainActor (CaptureLifecycleEvent) -> Void = { _ in }
        ) {
            self.makeDriver = makeDriver
            self.makeWorker = makeWorker
            self.onEvent = onEvent
        }

        isolated deinit {
            if let operation {
                beginStop(operation, change: .explicitStop, explicit: true, reportEvents: false)
            }
        }

        /// A conflicting/pending operation must finish first. No permission is queried here.
        public func prepareStart() throws -> CaptureLifecycleStartIntent {
            guard !delivering, operation == nil, state != .permissionPending else {
                throw conflict()
            }
            controlRevision = UUID()
            intent = controlRevision
            completion = nil
            state = .permissionPending
            let token = CaptureLifecycleStartIntent(owner: owner, generation: controlRevision)
            publish(.state(state, epoch: nil))
            return token
        }

        /// The host may choose resumption after an interruption. Use the completion's
        /// recovery intent, rather than preparing a new user start in a delayed system
        /// callback. A newer explicit stop always invalidates this permission.
        public func prepareResume(_ recovery: CaptureLifecycleRecoveryIntent) throws
            -> CaptureLifecycleStartIntent
        {
            guard !delivering, operation == nil else { throw conflict() }
            guard state == .interrupted, recovery.owner == owner,
                recovery.generation == controlRevision
            else { throw CaptureLifecycleFailure(stage: .command, reason: .invalidStartIntent) }
            return try prepareStart()
        }

        /// Stops and reclaims the old configuration before granting a fresh intent.
        /// Another stop/cancel during the await wins; it cannot be undone by this call.
        public func prepareReconfiguration() async throws -> CaptureLifecycleStartIntent {
            guard !delivering else { throw conflict() }
            controlRevision = UUID()
            let revision = controlRevision
            requestStop(change: .analysisConfiguration, explicit: true)
            let terminal = completion
            let report = await terminal?.value
            guard controlRevision == revision, !Task.isCancelled else { throw cancelled() }
            if let failure = report?.failures.first { throw failure }
            return try prepareStart()
        }

        @discardableResult public func start(
            intent token: CaptureLifecycleStartIntent, request: CaptureRequest,
            buffering: CaptureBuffering, workerLimits: CaptureLifecycleWorkerLimits,
            lease: IOSCaptureHostLease? = nil, calibration: CaptureCalibrationContext? = nil,
            analysis: @escaping CaptureLifecycleAnalysis
        ) async throws -> CaptureLifecycleConfiguration {
            guard !delivering, operation == nil else { throw conflict() }
            guard token.owner == owner, token.generation == intent, state == .permissionPending
            else {
                throw CaptureLifecycleFailure(stage: .command, reason: .invalidStartIntent)
            }
            if Task.isCancelled {
                stop()
                throw cancelled()
            }
            let successor = try nextEpoch.successor()
            intent = nil
            let op = Operation(generation: token.generation, epoch: nextEpoch)
            let driver = makeDriver { [weak self] signal in
                self?.receive(signal, generation: token.generation)
            }
            let worker = makeWorker()
            op.driver = driver
            op.worker = worker
            operation = op
            let startup = Task { @MainActor in
                try Task.checkCancellation()
                let input: CaptureLifecycleInput
                do {
                    input = try await driver.start(
                        request: request, buffering: buffering, epoch: op.epoch, lease: lease)
                } catch { throw lifecycleFailure(error, stage: .captureStart, epoch: op.epoch) }
                try Task.checkCancellation()
                guard input.observation.epoch == op.epoch else {
                    throw CaptureLifecycleFailure(
                        stage: .captureStart, reason: .invalidConfiguration, epoch: op.epoch)
                }
                do {
                    return try await worker.prepare(
                        input: input, analysis: analysis, limits: workerLimits)
                } catch {
                    throw lifecycleFailure(error, stage: .analysisPreparation, epoch: op.epoch)
                }
            }
            op.startup = startup
            state = .configuring
            publish(.state(state, epoch: op.epoch))
            do {
                let observed = try await withTaskCancellationHandler {
                    try await startup.value
                } onCancel: { [weak self] in
                    startup.cancel()
                    Task { @MainActor in self?.cancel(generation: token.generation) }
                }
                guard isCurrent(op), !Task.isCancelled else { throw cancelled(epoch: op.epoch) }
                op.startup = nil
                op.published = true
                nextEpoch = successor
                let previous = lastConfiguration
                lastConfiguration = observed
                configuration = observed
                state = .running
                publish(.configured(observed))
                guard isCurrent(op) else { throw cancelled(epoch: op.epoch) }
                if let calibration {
                    publish(.calibrationConfiguration(calibration.compare(with: observed.capture)))
                }
                guard isCurrent(op) else { throw cancelled(epoch: op.epoch) }
                if let previous {
                    let change: CaptureLifecycleChange?
                    if previous.analysisIdentity != observed.analysisIdentity {
                        change = .analysisConfiguration
                    } else if previous.capture.input != observed.capture.input {
                        change = .route
                    } else if previous.capture.processing != observed.capture.processing {
                        change = .sessionConfiguration
                    } else {
                        change = nil
                    }
                    if let change {
                        publish(.calibrationRevalidationRequired(previous.capture.epoch, change))
                    }
                }
                guard isCurrent(op) else { throw cancelled(epoch: op.epoch) }
                publish(.state(.running, epoch: op.epoch))
                guard isCurrent(op) else { throw cancelled(epoch: op.epoch) }
                startPump(op, worker: worker)
                return observed
            } catch {
                let problem = lifecycleFailure(error, stage: .captureStart, epoch: op.epoch)
                if !problem.expectedDuringStop { record(problem, in: op) }
                if !op.stopping {
                    beginStop(op, change: .explicitStop, explicit: problem.expectedDuringStop)
                }
                _ = await op.terminal?.value
                throw problem
            }
        }

        /// Invalidates permission/reconfiguration intents and suppresses old results immediately.
        /// Pending analysis is discarded; this is not lossless recording finalization.
        public func stop() {
            controlRevision = UUID()
            requestStop(change: .explicitStop, explicit: true)
        }

        public func cancel() { stop() }

        /// The foreground host forwards this event; it never authorizes a later restart.
        public func enteredBackground() {
            controlRevision = UUID()
            requestStop(change: .enteredBackground, explicit: false)
        }

        /// Binds to the operation stopped by this call, even if another caller starts later.
        public func finish() async -> CaptureLifecycleCompletion {
            stop()
            let terminal = completion
            return await terminal!.value
        }

        private func isCurrent(_ op: Operation) -> Bool {
            operation === op && !op.stopping
        }

        private func cancel(generation: UUID) {
            guard operation?.generation == generation else { return }
            stop()
        }

        private func startPump(_ op: Operation, worker: any CaptureLifecycleWorking) {
            op.pump = Task { @MainActor [weak self] in
                var failure: CaptureLifecycleFailure?
                do {
                    while !Task.isCancelled {
                        let batch = try await worker.next()
                        guard self?.deliver(batch, generation: op.generation) == true else { break }
                        if batch.ended {
                            throw CaptureLifecycleFailure(
                                stage: .analysis, reason: .unexpectedCaptureEnd, epoch: op.epoch)
                        }
                        if batch.idle {
                            try await Task.sleep(for: .milliseconds(5))
                        } else {
                            await Task.yield()
                        }
                    }
                } catch {
                    if !(error is CancellationError) {
                        let problem = lifecycleFailure(error, stage: .analysis, epoch: op.epoch)
                        if !problem.expectedDuringStop { failure = problem }
                    }
                }
                if let failure { self?.receive(.failed(failure), generation: op.generation) }
            }
        }

        private func deliver(_ batch: CaptureLifecycleBatch, generation: UUID) -> Bool {
            guard let op = operation, op.generation == generation, isCurrent(op) else {
                return false
            }
            for event in batch.events {
                guard isCurrent(op) else { return false }
                publish(.analysis(event))
            }
            return isCurrent(op)
        }

        private func receive(_ signal: CaptureLifecycleSignal, generation: UUID) {
            guard let op = operation, op.generation == generation else { return }
            switch signal {
            case .changed(let change):
                if !op.stopping {
                    controlRevision = UUID()
                    beginStop(op, change: change, explicit: false)
                }
            case .failed(let failure):
                if !failure.expectedDuringStop { record(failure, in: op) }
                if !op.stopping { beginStop(op, change: .explicitStop, explicit: false) }
            case .sessionDisposition(let disposition):
                op.disposition = disposition
                publish(.sessionDisposition(disposition))
            }
        }

        private func record(_ failure: CaptureLifecycleFailure, in op: Operation) {
            if failure.stage == .shutdown {
                if op.cleanup == nil { op.cleanup = failure }
            } else if op.primary == nil {
                op.primary = failure
            } else if op.primary?.reason != failure.reason, op.cleanup == nil {
                op.cleanup = failure
            }
        }

        private func requestStop(change: CaptureLifecycleChange, explicit: Bool) {
            intent = nil
            if let op = operation {
                if op.stopping {
                    op.explicitStop = op.explicitStop || explicit
                } else {
                    beginStop(op, change: change, explicit: explicit)
                }
            } else if completion == nil {
                configuration = nil
                state = explicit ? .stopped : .interrupted
                let report = CaptureLifecycleCompletion(
                    epoch: nil, change: change, failures: [], audioSessionDisposition: nil,
                    recoveryIntent: nil)
                completion = Task { report }
                publish(.state(state, epoch: nil))
                publish(.completed(report))
            } else if explicit, state == .interrupted {
                state = .stopped
                publish(.state(.stopped, epoch: nil))
            }
        }

        private func beginStop(
            _ op: Operation, change: CaptureLifecycleChange, explicit: Bool,
            reportEvents: Bool = true
        ) {
            guard !op.stopping else {
                op.explicitStop = op.explicitStop || explicit
                return
            }
            op.stopping = true
            op.explicitStop = explicit
            op.change = change
            op.recoveryIntent = CaptureLifecycleRecoveryIntent(
                owner: owner, generation: controlRevision)
            intent = nil
            configuration = nil
            op.startup?.cancel()
            op.pump?.cancel()
            op.driver?.stop()
            state = .stopping
            let terminal = Task { @MainActor [weak self] in
                if let startup = op.startup {
                    if case .failure(let error) = await startup.result {
                        let failure = lifecycleFailure(error, stage: .captureStart, epoch: op.epoch)
                        if !failure.expectedDuringStop, op.primary == nil { op.primary = failure }
                    }
                }
                op.driver?.stop()
                do { try await op.driver?.finish() } catch {
                    let failure = lifecycleFailure(error, stage: .shutdown, epoch: op.epoch)
                    if !failure.expectedDuringStop, op.primary?.reason != failure.reason,
                        op.cleanup == nil
                    {
                        op.cleanup = failure
                    }
                }
                await op.pump?.value
                await op.worker?.close()
                op.startup = nil
                op.pump = nil
                op.driver = nil
                op.worker = nil
                var failures = [op.primary, op.cleanup].compactMap { $0 }
                if failures.count == 2, failures[0].reason == failures[1].reason {
                    failures.removeLast()
                }
                let report = CaptureLifecycleCompletion(
                    epoch: op.published ? op.epoch : nil, change: op.change, failures: failures,
                    audioSessionDisposition: op.disposition,
                    recoveryIntent: !op.explicitStop && failures.isEmpty ? op.recoveryIntent : nil)
                self?.complete(op, report: report, reportEvents: reportEvents)
                return report
            }
            op.terminal = terminal
            completion = terminal
            if reportEvents {
                publish(.state(.stopping, epoch: op.published ? op.epoch : nil))
                if op.published {
                    // Successor was checked before any capture side effect.
                    if let boundary = try? SourceDiscontinuity(
                        previousEpoch: op.epoch, nextEpoch: nextEpoch, reason: change.resetReason)
                    {
                        publish(.discontinuity(boundary))
                    }
                    if change != .explicitStop {
                        publish(.calibrationRevalidationRequired(op.epoch, change))
                    }
                }
            }
        }

        private func complete(
            _ op: Operation, report: CaptureLifecycleCompletion, reportEvents: Bool
        ) {
            guard operation === op else { return }
            operation = nil
            state = !report.failures.isEmpty ? .failed : op.explicitStop ? .stopped : .interrupted
            if reportEvents {
                publish(.state(state, epoch: report.epoch))
                publish(.completed(report))
            }
        }

        private func publish(_ event: CaptureLifecycleEvent) {
            let prior = delivering
            delivering = true
            onEvent(event)
            delivering = prior
        }

        private func conflict() -> CaptureLifecycleFailure {
            CaptureLifecycleFailure(
                stage: .command, reason: .conflictingOperation, recovery: .waitForStopCompletion)
        }
        private func cancelled(epoch: StreamEpoch? = nil) -> CaptureLifecycleFailure {
            CaptureLifecycleFailure(stage: .command, reason: .cancelled, epoch: epoch)
        }
    }
#endif
