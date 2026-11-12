// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation
import Observation

@Observable
final class CHIICHReceiverAIService {
    enum Availability { case idle, checking, ready, unavailable }
    typealias Request = (CHIICHReceiverAIRequest, CHIICHReceiverAISourceContext?) async -> Result<Data, CHIICHReceiverAIError>
    typealias LoadAudio = (MediaSourceProxy, String) async -> Result<Data, CHIICHReceiverAIError>
    typealias RetryDelay = (Duration) async throws -> Void
    
    private struct Job {
        let event: CHIICHReceiverAIEvent
        let identity: String
        let source: String
        let language: String
        let generation: Int
        var cacheKey: String {
            source + ":" + language
        }
    }
    
    let accountID: String
    private(set) var availability = Availability.idle
    var consentDecision: CHIICHReceiverAIConsent.Decision { consent.decision }
    var enabled: Bool { consent.authorized }
    var language: String { preferenceState.value.language }
    var preferencesReady: Bool { preferenceState.isReady }
    var preferenceSyncFailed: Bool { preferenceState.syncFailed || consent.syncFailed }
    private(set) var audioAvailable = false
    private var sharedCacheAvailable = false
    var isActive: Bool {
        enabled && preferencesReady && !revisionLedgerFull && claims?.hasCapacity == true && availability == .ready && sessionIsCurrent()
    }
    
    private let detectLanguage: (String) -> String
    private let request: Request
    private let loadAudio: LoadAudio
    private let retryDelay: RetryDelay
    private let sessionIsCurrent: () -> Bool
    private let claims: CHIICHReceiverAIClaimStore?
    private let consent: CHIICHReceiverAIConsent
    private let preferenceState: CHIICHReceiverAIPreferences
    private var generation = 0
    private var visible: [UUID: [String: CHIICHReceiverAIEvent]] = [:]
    private var sources: [String: String] = [:]
    private var sourceOrder: [String] = []
    private var revisionTimestamps: [String: Int64] = [:]
    private var editedIdentities: Set<String> = []
    private var contentFingerprints: [String: String] = [:]
    private var redactedIdentities: Set<String> = []
    private var supersededSources: Set<String> = []
    private var revisionLedgerFull = false
    private var cache: [String: CHIICHReceiverAIPresentation] = [:]
    private var cacheOrder: [String] = []
    private var originals: Set<String> = []
    private var attemptedJobs: Set<String> = []
    private var queue: [Job] = []
    private var task: Task<Void, Never>?
    private var activeJob: Job?
    private var checkingID: UUID?
    
    init(accountID: String,
         request: @escaping Request,
         loadAudio: @escaping LoadAudio,
         sessionIsCurrent: @escaping () -> Bool,
         claims: CHIICHReceiverAIClaimStore?,
         preferences: UserDefaults = .standard,
         detectLanguage: @escaping (String) -> String = CHIICHReceiverAILanguage.detect,
         retryDelay: @escaping RetryDelay = { try await Task.sleep(for: $0) },
         preferenceState: CHIICHReceiverAIPreferences? = nil) {
        self.detectLanguage = detectLanguage
        self.accountID = accountID
        self.request = request
        self.loadAudio = loadAudio
        self.retryDelay = retryDelay
        self.sessionIsCurrent = sessionIsCurrent
        self.claims = claims
        consent = CHIICHReceiverAIConsent(accountID: accountID, defaults: preferences, request: request)
        self.preferenceState = preferenceState ?? CHIICHReceiverAIPreferences(accountID: accountID, defaults: preferences)
        self.preferenceState.onChange = { [weak self] in self?.configurationChanged() }
        consent.onChange = { [weak self] in self?.configurationChanged() }
    }
    
    convenience init(clientProxy: ClientProxyProtocol, mediaProvider: MediaProviderProtocol, contentScannerService: ContentScannerServiceProtocol?) {
        let accountID = clientProxy.userID
        self.init(accountID: accountID,
                  request: { [weak clientProxy] request, source in
                      guard let clientProxy else { return .failure(.unavailable) }
                      return await clientProxy.chiichReceiverAIRequest(request, source: source, accountID: accountID)
                  },
                  loadAudio: { source, filename in
                      await Self.audioData(source: source, filename: filename, provider: mediaProvider, scanner: contentScannerService)
                  },
                  sessionIsCurrent: { [weak clientProxy] in
                      clientProxy?.userID == accountID && clientProxy?.chiichReceiverAIIsSessionActive == true
                  },
                  claims: try? CHIICHReceiverAIClaimStore(accountID: accountID),
                  preferenceState: CHIICHReceiverAIPreferences(accountID: accountID,
                                                             read: { [weak clientProxy] in
                                                                 guard let clientProxy, clientProxy.chiichReceiverAIIsSessionActive, clientProxy.userID == accountID else { return .failure(.unavailable) }
                                                                 return await clientProxy.chiichReceiverAIPreferences(accountID: accountID)
                                                             },
                                                             write: { [weak clientProxy] value in
                                                                 guard let clientProxy, clientProxy.chiichReceiverAIIsSessionActive, clientProxy.userID == accountID else { return .failure(.unavailable) }
                                                                 return await clientProxy.setCHIICHReceiverAIPreferences(value, accountID: accountID)
                                                             }))
    }
    
    // One presentation per session; a recorded grant/refusal is shared across devices.
    // Opening a screen never authorizes processing or writes a choice.
    private var didPresentAutomaticConsent = false

    func prepareAutomaticConsentPrompt() async -> Bool {
        guard sessionIsCurrent(), !Task.isCancelled, !didPresentAutomaticConsent else { return false }
        await consent.refresh()
        guard sessionIsCurrent(), !Task.isCancelled, !didPresentAutomaticConsent,
              !consent.syncFailed, consent.decision == .undecided else { return false }
        didPresentAutomaticConsent = true
        return true
    }

    func connectIfNeeded() async {
        guard availability == .idle else { return }
        await refreshConnection()
    }
    
    func refreshConnection() async {
        await consent.refresh(force: true)
        await preferenceState.refresh()
        guard availability != .checking, sessionIsCurrent(), claims?.hasCapacity == true, !revisionLedgerFull else {
            if claims?.hasCapacity != true || !sessionIsCurrent() || revisionLedgerFull {
                availability = .unavailable
            }
            return
        }
        let checkID = UUID()
        checkingID = checkID
        availability = .checking
        let response = await request(.status, nil)
        guard checkingID == checkID else { return }
        guard sessionIsCurrent(), !Task.isCancelled else {
            checkingID = nil
            availability = .unavailable
            return
        }
        checkingID = nil
        guard case .success(let data) = response,
              let status = try? JSONDecoder().decode(CHIICHReceiverAIStatus.self, from: data), status.isAvailable else {
            availability = .unavailable
            audioAvailable = false
            return
        }
        audioAvailable = status.capabilities.audio
        sharedCacheAvailable = status.capabilities.cacheLookup == true
        availability = .ready
        scheduleVisible()
    }
    
    func setConsent(_ granted: Bool) {
        guard sessionIsCurrent() else { return }
        consent.select(granted)
        if !granted { preferenceState.setEnabled(false) }
    }

    func setLanguage(_ value: String) {
        preferenceState.setLanguage(value)
    }

    func synchronizePreferences(accountDataSynced: Bool = false) async {
        await consent.refresh()
        await preferenceState.refresh(accountDataSynced: accountDataSynced)
    }

    func setPreferencesMonitoring(active: Bool) {
        if active {
            preferenceState.startMonitoring()
            Task { [weak self] in await self?.consent.refresh(force: true) }
        } else {
            preferenceState.stopMonitoring()
        }
    }

    func show(_ event: CHIICHReceiverAIEvent, owner: UUID) {
        guard event.senderID != accountID else { return }
        register(event)
        let identity = event.identity(accountID: accountID)
        guard !redactedIdentities.contains(identity), sources[identity] == event.source(accountID: accountID) else { return }
        visible[owner, default: [:]][identity] = event
        enqueue(event)
    }
    
    func hide(roomID: String, eventID: String, owner: UUID) {
        let identity = CHIICHReceiverAIIdentity.event(accountID: accountID, roomID: roomID, eventID: eventID)
        visible[owner]?[identity] = nil
        if visible[owner]?.isEmpty == true {
            visible[owner] = nil
        }
        queue.removeAll { $0.identity == identity && !isVisible(identity) }
    }
    
    func removeOwner(_ owner: UUID) {
        visible[owner] = nil
        queue.removeAll { !isVisible($0.identity) }
    }
    
    func register(_ event: CHIICHReceiverAIEvent) {
        let identity = event.identity(accountID: accountID)
        let source = event.source(accountID: accountID)
        guard !revisionLedgerFull, !redactedIdentities.contains(identity), sources[identity] != source,
              !supersededSources.contains(source), acceptsRevision(event, identity: identity) else { return }
        if let previous = sources[identity] {
            guard supersededSources.count < 4096 else { blockRevisionLedger(); return }
            supersededSources.insert(previous)
            removeCached(source: previous)
            queue.removeAll { $0.identity == identity }
            if activeJob?.identity == identity {
                task?.cancel()
            }
        }
        sources[identity] = source
        revisionTimestamps[identity] = event.revisionTimestamp
        contentFingerprints[identity] = event.contentFingerprint
        if event.revision != event.eventID {
            editedIdentities.insert(identity)
        }
        sourceOrder.removeAll { $0 == identity }
        sourceOrder.append(identity)
        while sourceOrder.count > 512 {
            guard let index = sourceOrder.firstIndex(where: { !isVisible($0) && activeJob?.identity != $0 }) else { break }
            let oldest = sourceOrder.remove(at: index)
            revisionTimestamps[oldest] = nil
            contentFingerprints[oldest] = nil
            editedIdentities.remove(oldest)
            if let oldSource = sources.removeValue(forKey: oldest) {
                removeCached(source: oldSource)
            }
        }
        for owner in Array(visible.keys) where visible[owner]?[identity] != nil {
            visible[owner]?[identity] = event
        }
        if isVisible(identity) {
            enqueue(event)
        }
    }
    
    func redact(roomID: String, eventID: String) {
        let identity = CHIICHReceiverAIIdentity.event(accountID: accountID, roomID: roomID, eventID: eventID)
        guard redactedIdentities.contains(identity) || redactedIdentities.count < 4096 else { blockRevisionLedger(); return }
        redactedIdentities.insert(identity)
        discard(identity: identity)
    }
    
    func suspend(roomID: String, eventID: String) {
        discard(identity: CHIICHReceiverAIIdentity.event(accountID: accountID, roomID: roomID, eventID: eventID))
    }
    
    private func discard(identity: String) {
        revisionTimestamps[identity] = nil
        contentFingerprints[identity] = nil
        editedIdentities.remove(identity)
        if let source = sources.removeValue(forKey: identity) {
            removeCached(source: source)
        }
        sourceOrder.removeAll { $0 == identity }
        for owner in Array(visible.keys) {
            visible[owner]?[identity] = nil
        }
        queue.removeAll { $0.identity == identity }
        if activeJob?.identity == identity {
            task?.cancel()
        }
    }
    
    func invalidate() {
        consent.invalidate()
        preferenceState.invalidate()
        generation += 1
        checkingID = nil
        task?.cancel()
        queue.removeAll()
        visible.removeAll()
        sources.removeAll()
        revisionTimestamps.removeAll()
        contentFingerprints.removeAll()
        editedIdentities.removeAll()
        sourceOrder.removeAll()
        cache.removeAll()
        cacheOrder.removeAll()
        originals.removeAll()
        attemptedJobs.removeAll()
        availability = .unavailable
    }
    
    func presentation(roomID: String, eventID: String?, originalFingerprint: String? = nil) -> CHIICHReceiverAIPresentation? {
        guard enabled, sessionIsCurrent(), let eventID else { return nil }
        let identity = CHIICHReceiverAIIdentity.event(accountID: accountID, roomID: roomID, eventID: eventID)
        guard originalFingerprint == nil || originalFingerprint == contentFingerprints[identity],
              let source = sources[identity], let result = cache[source + ":" + language] else { return nil }
        if originals.contains(source + ":" + language) {
            guard let transcript = result.originalTranscript else { return nil }
            return .init(text: transcript, originalTranscript: transcript)
        }
        return result
    }
    
    func originalAction(roomID: String, eventID: String?) -> TimelineItemMenuAction? {
        guard enabled, sessionIsCurrent(), let eventID,
              let source = sources[CHIICHReceiverAIIdentity.event(accountID: accountID, roomID: roomID, eventID: eventID)],
              cache[source + ":" + language]?.canShowOriginal == true else { return nil }
        return .chiichShowOriginal(showOriginal: !originals.contains(source + ":" + language))
    }
    
    func toggleOriginal(roomID: String, eventID: String?) {
        guard let eventID, let source = sources[CHIICHReceiverAIIdentity.event(accountID: accountID, roomID: roomID, eventID: eventID)] else { return }
        let key = source + ":" + language
        if originals.contains(key) {
            originals.remove(key)
        } else {
            originals.insert(key)
        }
    }
    
    private func acceptsRevision(_ event: CHIICHReceiverAIEvent, identity: String) -> Bool {
        guard let previous = revisionTimestamps[identity] else { return true }
        if editedIdentities.contains(identity), event.revision == event.eventID {
            return false
        }
        if event.revisionTimestamp > previous {
            return true
        }
        if event.revisionTimestamp < previous {
            return false
        }
        return !editedIdentities.contains(identity) && event.revision != event.eventID
    }
    
    private func blockRevisionLedger() {
        revisionLedgerFull = true
        invalidate()
    }
    
    private func configurationChanged() {
        generation += 1
        queue.removeAll()
        task?.cancel()
        if !enabled {
            cache.removeAll()
            cacheOrder.removeAll()
            originals.removeAll()
        }
        scheduleVisible()
    }
    
    private func scheduleVisible() {
        for events in visible.values {
            for event in events.values {
                enqueue(event)
            }
        }
    }
    
    private func isVisible(_ identity: String) -> Bool {
        visible.values.contains { $0[identity] != nil }
    }
    
    private func enqueue(_ event: CHIICHReceiverAIEvent) {
        guard isActive, event.senderID != accountID, queue.count < 24 else { return }
        let job = Job(event: event, identity: event.identity(accountID: accountID), source: event.source(accountID: accountID), language: language, generation: generation)
        guard cache[job.cacheKey] == nil, !attemptedJobs.contains(job.cacheKey),
              activeJob?.cacheKey != job.cacheKey || activeJob?.generation != generation,
              !queue.contains(where: { $0.cacheKey == job.cacheKey }) else { return }
        queue.append(job)
        startNext()
    }
    
    private func startNext() {
        guard task == nil, isActive else { return }
        while !queue.isEmpty {
            let job = queue.removeFirst()
            guard isVisible(job.identity), sources[job.identity] == job.source, cache[job.cacheKey] == nil else { continue }
            activeJob = job
            task = Task { [weak self] in
                guard let self else { return }
                await process(job)
                task = nil
                activeJob = nil
                scheduleVisible()
                startNext()
            }
            return
        }
    }
    
    private func isCurrent(_ job: Job) -> Bool {
        !Task.isCancelled && sessionIsCurrent() && enabled && job.generation == generation && sources[job.identity] == job.source
    }
    
    private func process(_ job: Job) async {
        do {
            guard isCurrent(job), isVisible(job.identity) else { return }
            let presentation: CHIICHReceiverAIPresentation
            switch job.event.content {
            case .text(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 12000 else {
                    attemptedJobs.insert(job.cacheKey)
                    return
                }
                let sourceLanguage = detectLanguage(text)
                let operation = CHIICHReceiverAILanguage.operation(source: sourceLanguage, target: job.language)
                let result = try await assist(text: text, sourceLanguage: sourceLanguage, operation: operation, job: job)
                presentation = .init(text: result.text, originalTranscript: nil)
            case .audio(let source, let filename, let size):
                guard let result = try await processAudio(source: source, filename: filename, size: size, job: job) else { return }
                presentation = result
            }
            guard isCurrent(job) else { return }
            put(presentation, for: job)
        } catch CHIICHReceiverAIError.cancelled {
            return
        } catch CHIICHReceiverAIError.consentRequired {
            // This message does not have a verified source with two current grants.
            // Suppress it for this session; other conversations remain usable.
            attemptedJobs.insert(job.cacheKey)
            return
        } catch CHIICHReceiverAIError.alreadyAttempted {
            attemptedJobs.insert(job.cacheKey)
            return
        } catch {
            // Never retry an uncertain paid call. Normal Matrix rendering remains available.
            guard isCurrent(job) else { return }
            availability = .unavailable
            queue.removeAll()
        }
    }
    
    private func processAudio(source: MediaSourceProxy, filename: String, size: UInt?, job: Job) async throws -> CHIICHReceiverAIPresentation? {
        guard audioAvailable, size.map({ $0 <= CHIICHReceiverAIRequest.audioLimit }) ?? true,
              let mimeType = source.mimeType?.lowercased().split(separator: ";").first.map(String.init),
              CHIICHReceiverAIRequest.mimeTypes.contains(mimeType) else {
            attemptedJobs.insert(job.cacheKey)
            return nil
        }
        let requestID = CHIICHReceiverAIIdentity.request(source: job.source, operation: "transcribe", language: "original")
        // Native download is unpaid preparation. An offscreen cancellation here must not
        // create an attempt tombstone: returning to the message can still start its first ASR.
        let data = try await loadAudio(source, filename).get()
        guard isCurrent(job), isVisible(job.identity) else { return nil }
        guard !data.isEmpty, data.count <= CHIICHReceiverAIRequest.audioLimit else {
            attemptedJobs.insert(job.cacheKey)
            return nil
        }
        let query = CHIICHReceiverAICacheQuery(requestID: requestID, audio: data, mimeType: mimeType)
        let transcript = try await cachedOrPaid(.transcribe(requestID: requestID, data: data, mimeType: mimeType, reuseCache: sharedCacheAvailable), query: query, job: job)
        guard isCurrent(job) else { return nil }
        let sourceLanguage = CHIICHReceiverAILanguage.normalize(transcript.language ?? "und")
        if CHIICHReceiverAILanguage.valid(sourceLanguage), sourceLanguage != "und", sourceLanguage != job.language, transcript.text.utf16.count <= 12000 {
            // A failed translation must not erase a successful original transcript.
            put(.init(text: transcript.text, originalTranscript: transcript.text), for: job)
            let translated = try await assist(text: transcript.text, sourceLanguage: sourceLanguage, operation: .translate, job: job)
            return .init(text: translated.text, originalTranscript: transcript.text)
        } else {
            return .init(text: transcript.text, originalTranscript: transcript.text)
        }
    }
    
    private func assist(text: String, sourceLanguage: String, operation: CHIICHReceiverAIOperation, job: Job) async throws -> CHIICHReceiverAIResponse {
        guard isCurrent(job) else { throw CHIICHReceiverAIError.cancelled }
        let requestID = CHIICHReceiverAIIdentity.request(source: job.source, operation: "assist", language: job.language)
        var payload = CHIICHReceiverAIAssist(operation: operation, text: text, requestId: requestID, sourceLanguage: sourceLanguage, targetLanguage: job.language)
        // The old web text controller used the combined operation with sourceLanguage=und.
        // Only that equivalent original-text payload is considered; transcripts never use it.
        let isText: Bool = if case .text = job.event.content { true } else { false }
        if sharedCacheAvailable { payload.includeLegacyText = isText }
        let query = CHIICHReceiverAICacheQuery(assist: payload, includeLegacyText: isText)
        return try await cachedOrPaid(.assist(payload), query: query, job: job)
    }
    
    private func cachedOrPaid(_ payload: CHIICHReceiverAIRequest, query: CHIICHReceiverAICacheQuery, job: Job) async throws -> CHIICHReceiverAIResponse {
        guard isCurrent(job) else { throw CHIICHReceiverAIError.cancelled }
        // During a rolling server update retain the existing native request IDs and claims.
        // Once cache lookup is advertised, a failed probe NEVER falls back to a paid call.
        guard sharedCacheAvailable else { return try await paid(payload, requestID: query.requestId, job: job) }
        let data = try await request(.cache(query), sourceContext(job, transcribedText: query.assist != nil)).get()
        let cached = try JSONDecoder().decode(CHIICHReceiverAICacheResponse.self, from: data).validated(for: query.requestId)
        guard isCurrent(job) else { throw CHIICHReceiverAIError.cancelled }
        switch cached.state {
        case .ready:
            guard let result = cached.result else { throw CHIICHReceiverAIError.invalidResponse }
            attemptedJobs.insert(job.cacheKey)
            return result
        case .blocked:
            // Pending, expired and uncertain server operations must not be repurchased
            // under the native namespace, even when they originated in the web client.
            guard let claims else { throw CHIICHReceiverAIError.storageUnavailable }
            if !claims.contains(query.requestId) { try claims.claim(query.requestId) }
            throw CHIICHReceiverAIError.alreadyAttempted
        case .missing:
            guard isVisible(job.identity) || cache[job.cacheKey]?.originalTranscript != nil else { throw CHIICHReceiverAIError.cancelled }
            return try await paid(payload, requestID: query.requestId, job: job)
        }
    }

    private func sourceContext(_ job: Job, transcribedText: Bool) -> CHIICHReceiverAISourceContext {
        let event = job.event
        // A synthetic ":edited" identity does not identify a verifiable replacement. The
        // gateway still checks actual Matrix content; an unverifiable edit stays original.
        let sourceID = event.revision == event.eventID + ":edited" ? event.eventID : event.revision
        var context = CHIICHReceiverAISourceContext(roomID: event.roomID, eventID: sourceID)
        if transcribedText, case .audio = event.content {
            context.transcriptRequestID = CHIICHReceiverAIIdentity.request(source: job.source, operation: "transcribe", language: "original")
        }
        return context
    }

    private func paid(_ payload: CHIICHReceiverAIRequest, requestID: String, job: Job) async throws -> CHIICHReceiverAIResponse {
        guard let claims else { throw CHIICHReceiverAIError.storageUnavailable }
        let delays: [Duration] = [.milliseconds(500), .milliseconds(1500), .milliseconds(3000)]
        for attempt in 0...delays.count {
            guard isCurrent(job), isVisible(job.identity) || cache[job.cacheKey]?.originalTranscript != nil else { throw CHIICHReceiverAIError.cancelled }
            try claims.claim(requestID)
            attemptedJobs.insert(job.cacheKey)
            do {
                let isText: Bool = if case .assist = payload { true } else { false }
                let data = try await request(payload, sourceContext(job, transcribedText: isText)).get()
                let response = try JSONDecoder().decode(CHIICHReceiverAIResponse.self, from: data).validated(for: requestID)
                try Task.checkCancellation()
                guard sessionIsCurrent() else { throw CHIICHReceiverAIError.cancelled }
                try claims.complete(requestID)
                return response
            } catch CHIICHReceiverAIError.consentRequired {
                // A refusal precedes any external call; do not burn a permanent paid claim.
                try claims.complete(requestID)
                throw CHIICHReceiverAIError.consentRequired
            } catch CHIICHReceiverAIError.preclaimBusy {
                // Only the authenticated gateway's exact pre-claim AI_BUSY can release
                // this marker. Every uncertain/paid failure remains blocked after restart.
                try claims.complete(requestID)
                attemptedJobs.remove(job.cacheKey)
                guard attempt < delays.count else { throw CHIICHReceiverAIError.preclaimBusy }
                try await retryDelay(delays[attempt])
            }
        }
        throw CHIICHReceiverAIError.preclaimBusy
    }

    private func put(_ result: CHIICHReceiverAIPresentation, for job: Job) {
        cache[job.cacheKey] = result
        cacheOrder.removeAll { $0 == job.cacheKey }
        cacheOrder.append(job.cacheKey)
        while cacheOrder.count > 64 || cache.values.reduce(0, { $0 + $1.text.utf16.count + ($1.originalTranscript?.utf16.count ?? 0) }) > 500_000 {
            let oldest = cacheOrder.removeFirst()
            cache[oldest] = nil
            originals.remove(oldest)
        }
    }
    
    private func removeCached(source: String) {
        for key in Array(cache.keys) where key.hasPrefix(source + ":") {
            cache[key] = nil
            originals.remove(key)
        }
        cacheOrder.removeAll { $0.hasPrefix(source + ":") }
        attemptedJobs = attemptedJobs.filter { !$0.hasPrefix(source + ":") }
    }
    
    private nonisolated static func audioData(source: MediaSourceProxy, filename: String, provider: MediaProviderProtocol, scanner: ContentScannerServiceProtocol?) async -> Result<Data, CHIICHReceiverAIError> {
        if let scanner {
            guard case .success(true) = await scanner.loadScanResultFromSource(source) else { return .failure(.unavailable) }
        }
        guard case .success(let handle) = await provider.loadFileFromSource(source, filename: filename),
              let url = handle.url else { return .failure(.unavailable) }
        do {
            return try withExtendedLifetime(handle) {
                let attributes = try url.resourceValues(forKeys: [.fileSizeKey])
                guard let size = attributes.fileSize, size > 0, size <= CHIICHReceiverAIRequest.audioLimit else {
                    return .failure(.invalidRequest)
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= CHIICHReceiverAIRequest.audioLimit else { return .failure(.invalidRequest) }
                return .success(data)
            }
        } catch { return .failure(.unavailable) }
    }
}
