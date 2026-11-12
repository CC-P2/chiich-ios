// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import Testing

final class CHIICHReceiverAIServiceTests {
    @Test
    func firstChatOffersConsentOnceWithoutProcessingOrChoosing() async throws {
        let fixture = try Fixture()
        fixture.gateway.consent = nil
        let service = try fixture.makeService()
        #expect(await service.prepareAutomaticConsentPrompt())
        #expect(!(await service.prepareAutomaticConsentPrompt()))
        #expect(service.consentDecision == .undecided && !service.enabled)
        #expect(fixture.gateway.consentWrites.isEmpty && fixture.gateway.contexts.isEmpty)
        #expect(fixture.audioLoads == 0)
    }

    @Test(arguments: [true, false])
    func rememberedChoiceDoesNotPromptAgain(_ choice: Bool) async throws {
        let fixture = try Fixture()
        fixture.gateway.consent = choice
        let service = try fixture.makeService()
        #expect(!(await service.prepareAutomaticConsentPrompt()))
        #expect(fixture.gateway.consentWrites.isEmpty)
    }

    @Test
    func refusedFirstChatStaysOffAfterRestart() async throws {
        let fixture = try Fixture()
        fixture.gateway.consent = nil
        let service = try fixture.makeService()
        #expect(await service.prepareAutomaticConsentPrompt())
        service.setConsent(false)
        try await Self.waitUntil { fixture.gateway.consent == false }
        service.invalidate()
        let restored = try fixture.makeService()
        #expect(!(await restored.prepareAutomaticConsentPrompt()))
        #expect(!restored.enabled && fixture.gateway.contexts.isEmpty)
    }

    @Test
    func failedConsentReadDoesNotPromptOrAuthorize() async throws {
        let fixture = try Fixture()
        fixture.gateway.failConsentRead = true
        let service = try fixture.makeService()
        #expect(!(await service.prepareAutomaticConsentPrompt()))
        #expect(!service.enabled && fixture.gateway.consentWrites.isEmpty)
    }

    @Test
    func legacyEnabledCannotDiscloseTextOrVoiceBeforeAnExplicitDecision() async throws {
        let fixture = try Fixture()
        fixture.gateway.consent = nil
        fixture.gateway.cacheLookup = true
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try service.show(Self.audioEvent(), owner: UUID())
        await Task.yield()
        #expect(service.consentDecision == .undecided)
        #expect(!service.enabled && fixture.gateway.contexts.isEmpty && fixture.audioLoads == 0)
        #expect(fixture.gateway.consentWrites.isEmpty)
        service.setConsent(false)
        try await Self.waitUntil { fixture.gateway.consentWrites == [false] }
        #expect(service.consentDecision == .declined && fixture.gateway.contexts.isEmpty)
        service.setConsent(true)
        try await Self.waitUntil { !fixture.gateway.assists.isEmpty }
        #expect(service.consentDecision == .granted && service.enabled)
        #expect(fixture.gateway.contexts.contains { $0.roomID == Self.room && $0.eventID == "$event" })
    }

    @Test
    func oldServerCapabilityDoesNotAuthorizeAnyContentRequest() async throws {
        let fixture = try Fixture()
        fixture.gateway.consentVersion = 0
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try service.show(Self.audioEvent(), owner: UUID())
        await Task.yield()
        #expect(fixture.gateway.contexts.isEmpty && fixture.audioLoads == 0 && !service.isActive)
    }

    @Test
    func offlineWithdrawalSurvivesRestartAndRemoteRevokeHidesCachedResults() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$event") != nil }
        fixture.gateway.consent = false
        await service.refreshConnection()
        #expect(service.presentation(roomID: Self.room, eventID: "$event") == nil)
        fixture.gateway.consent = true
        await service.refreshConnection()
        fixture.gateway.failConsentWrite = true
        service.setConsent(false)
        try await Self.waitUntil { service.preferenceSyncFailed }
        #expect(!service.enabled)
        service.invalidate()
        let restored = try fixture.makeService()
        fixture.gateway.failConsentWrite = false
        await restored.connectIfNeeded()
        #expect(fixture.gateway.consent == false)
        #expect(restored.consentDecision == .declined && !restored.enabled)
    }

    @Test
    func disconnectedProviderLeavesOriginalChatAndDoesNotProcessMessages() async throws {
        let fixture = try Fixture()
        fixture.gateway.configured = false
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        #expect(service.availability == .unavailable)
        #expect(fixture.gateway.paidRequests.isEmpty)
        #expect(service.presentation(roomID: Self.room, eventID: "$event") == nil)
    }
    
    @Test
    func outgoingMessagesNeverReachTheProvider() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(sender: Self.account), owner: UUID())
        #expect(fixture.gateway.paidRequests.isEmpty)
        #expect(service.presentation(roomID: Self.room, eventID: "$event") == nil)
    }
    
    @Test
    func sameLanguageRewriteAndOriginalToggleReuseOneResult() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        let event = Self.textEvent()
        let owner = UUID()
        service.show(event, owner: owner)
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$event") != nil }
        let payload = try #require(fixture.gateway.assists.first)
        #expect(payload.operation == .rewrite)
        #expect(payload.text == Self.originalEnglish)
        service.toggleOriginal(roomID: Self.room, eventID: "$event")
        #expect(service.presentation(roomID: Self.room, eventID: "$event") == nil)
        #expect(service.originalAction(roomID: Self.room, eventID: "$event") == .chiichShowOriginal(showOriginal: false))
        service.toggleOriginal(roomID: Self.room, eventID: "$event")
        service.hide(roomID: Self.room, eventID: "$event", owner: owner)
        service.show(event, owner: owner)
        #expect(service.presentation(roomID: Self.room, eventID: "$event")?.text == "Processed original")
        #expect(fixture.gateway.paidRequests.count == 1)
    }
    
    @Test
    func foreignTextTranslatesOriginalInOneOperation() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        let text = "Это подробное исходное сообщение на русском языке. Пожалуйста, переведите его на английский язык."
        service.show(Self.textEvent(text: text), owner: UUID())
        try await Self.waitUntil { !fixture.gateway.assists.isEmpty }
        #expect(fixture.gateway.assists.first?.operation == .translate)
        #expect(fixture.gateway.assists.first?.text == text)
        #expect(fixture.gateway.assists.count == 1)
    }
    
    @Test
    func voiceAlwaysTranscribesAndTranslatesTheRawTranscript() async throws {
        let fixture = try Fixture()
        fixture.gateway.transcriptLanguage = "zh"
        fixture.gateway.transcript = "这是原始语音的转写内容。"
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        try service.show(Self.audioEvent(), owner: UUID())
        try await Self.waitUntil { fixture.gateway.assists.count == 1 }
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$voice")?.text == "Processed original" }
        #expect(fixture.audioLoads == 1)
        #expect(fixture.gateway.transcriptions == 1)
        #expect(fixture.gateway.assists.first?.operation == .translate)
        #expect(fixture.gateway.assists.first?.text == fixture.gateway.transcript)
        service.toggleOriginal(roomID: Self.room, eventID: "$voice")
        #expect(service.presentation(roomID: Self.room, eventID: "$voice")?.text == fixture.gateway.transcript)
        #expect(fixture.gateway.paidRequests.count == 2)
    }
    
    @Test(arguments: ["en", "und", ""])
    func sameOrUnknownVoiceLanguageNeverRewritesOrTranslates(_ language: String) async throws {
        let fixture = try Fixture()
        fixture.gateway.transcriptLanguage = language
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        try service.show(Self.audioEvent(), owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$voice") != nil }
        #expect(fixture.gateway.transcriptions == 1)
        #expect(fixture.gateway.assists.isEmpty)
        #expect(service.presentation(roomID: Self.room, eventID: "$voice")?.text == fixture.gateway.transcript)
    }
    
    @Test
    func translationFailurePreservesSuccessfulOriginalVoiceTranscript() async throws {
        let fixture = try Fixture()
        fixture.gateway.transcriptLanguage = "ru"
        fixture.gateway.failAssist = true
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        try service.show(Self.audioEvent(), owner: UUID())
        try await Self.waitUntil { service.availability == .unavailable }
        #expect(service.presentation(roomID: Self.room, eventID: "$voice")?.text == fixture.gateway.transcript)
        #expect(fixture.gateway.transcriptions == 1)
    }
    
    @Test
    func audioLimitIsCheckedBeforeNativeDownloadOrProviderCall() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        try service.show(Self.audioEvent(size: 25_000_001), owner: UUID())
        await Task.yield()
        #expect(fixture.audioLoads == 0)
        #expect(fixture.gateway.paidRequests.isEmpty)
    }
    
    @Test
    func completedResultsUseStableServerCacheAfterRestart() async throws {
        let fixture = try Fixture()
        let first = try fixture.makeService()
        await first.connectIfNeeded()
        first.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { first.presentation(roomID: Self.room, eventID: "$event") != nil }
        first.invalidate()
        let second = try fixture.makeService()
        await second.connectIfNeeded()
        second.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { second.presentation(roomID: Self.room, eventID: "$event") != nil }
        #expect(fixture.gateway.assists.count == 2)
        #expect(fixture.gateway.assists[0].requestId == fixture.gateway.assists[1].requestId)
        #expect(fixture.gateway.providerCalls == 1)
    }
    
    @Test
    func uncertainRequestIsNotRetriedAfterScrollExplicitStatusCheckOrRestart() async throws {
        let fixture = try Fixture()
        fixture.gateway.failAssist = true
        let first = try fixture.makeService()
        await first.connectIfNeeded()
        let owner = UUID()
        first.show(Self.textEvent(), owner: owner)
        try await Self.waitUntil { first.availability == .unavailable }
        first.hide(roomID: Self.room, eventID: "$event", owner: owner)
        first.show(Self.textEvent(), owner: owner)
        await first.refreshConnection()
        await Task.yield()
        first.invalidate()
        let second = try fixture.makeService()
        await second.connectIfNeeded()
        second.show(Self.textEvent(), owner: UUID())
        await Task.yield()
        #expect(fixture.gateway.assists.count == 1)
        fixture.gateway.failAssist = false
        second.show(Self.textEvent(id: "$different"), owner: UUID())
        try await Self.waitUntil { second.presentation(roomID: Self.room, eventID: "$different") != nil }
        #expect(fixture.gateway.assists.count == 2)
    }
    
    @Test
    func editInvalidatesCachedResultAndUsesNewRevisionRequest() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$event") != nil }
        let edited = Self.textEvent(text: "This is a different edited message that must replace the previous result.", revision: "$edit2")
        service.register(edited)
        #expect(service.presentation(roomID: Self.room, eventID: "$event") == nil)
        try await Self.waitUntil { fixture.gateway.assists.count == 2 }
        #expect(fixture.gateway.assists[0].requestId != fixture.gateway.assists[1].requestId)
        #expect(fixture.gateway.assists[1].text != fixture.gateway.assists[0].text)
    }
    
    @Test
    func redactionDuringRequestDiscardsLateResultAndClearsOriginalAction() async throws {
        let fixture = try Fixture()
        fixture.gateway.holdAssist = true
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { fixture.gateway.continuation != nil }
        service.redact(roomID: Self.room, eventID: "$event")
        fixture.gateway.releaseAssist()
        await Task.yield()
        #expect(service.presentation(roomID: Self.room, eventID: "$event") == nil)
        #expect(service.originalAction(roomID: Self.room, eventID: "$event") == nil)
        #expect(fixture.gateway.assists.count == 1)
    }
    
    @Test
    func accountInvalidationDropsLateReplyAndCachedContent() async throws {
        let fixture = try Fixture()
        fixture.gateway.holdAssist = true
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { fixture.gateway.continuation != nil }
        fixture.sessionActive = false
        service.invalidate()
        fixture.gateway.releaseAssist()
        await Task.yield()
        #expect(!service.isActive)
        #expect(service.presentation(roomID: Self.room, eventID: "$event") == nil)
    }
    
    @Test
    func hiddenQueuedItemDoesNotMakePaidRequest() async throws {
        let fixture = try Fixture()
        fixture.gateway.holdAssist = true
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        let owner = UUID()
        service.show(Self.textEvent(), owner: owner)
        try await Self.waitUntil { fixture.gateway.continuation != nil }
        service.show(Self.textEvent(id: "$hidden"), owner: owner)
        service.hide(roomID: Self.room, eventID: "$hidden", owner: owner)
        fixture.gateway.releaseAssist()
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$event") != nil }
        await Task.yield()
        #expect(fixture.gateway.assists.count == 1)
    }
    
    @Test
    func staleOwnerCannotResurrectRedaction() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        let event = Self.textEvent()
        service.show(event, owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: event.eventID) != nil }
        service.redact(roomID: Self.room, eventID: event.eventID)
        service.register(event)
        service.show(event, owner: UUID())
        await Task.yield()
        #expect(service.presentation(roomID: Self.room, eventID: event.eventID) == nil)
        #expect(fixture.gateway.assists.count == 1)
    }
    
    @Test
    func staleOwnerCannotRollBackEditOrDisplayAnotherRevision() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        let original = Self.textEvent()
        service.show(original, owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: original.eventID) != nil }
        var edited = Self.textEvent(text: "The newly edited incoming message must stay current in every active timeline.", revision: "$edit2")
        edited.revisionTimestamp = 2
        service.register(edited)
        try await Self.waitUntil { fixture.gateway.assists.count == 2 }
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: edited.eventID) != nil }
        service.register(original)
        service.show(original, owner: UUID())
        var olderEdit = Self.textEvent(text: "An older edit from a stale timeline.", revision: "$edit1")
        olderEdit.revisionTimestamp = 1
        service.register(olderEdit)
        await Task.yield()
        #expect(fixture.gateway.assists.count == 2)
        #expect(service.presentation(roomID: Self.room, eventID: original.eventID, originalFingerprint: original.contentFingerprint) == nil)
        #expect(service.presentation(roomID: Self.room, eventID: edited.eventID, originalFingerprint: edited.contentFingerprint) != nil)
    }
    
    @Test
    func temporaryDecryptionFailureDoesNotCreateRedactionTombstone() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.suspend(roomID: Self.room, eventID: "$event")
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$event") != nil }
        #expect(fixture.gateway.assists.count == 1)
    }
    
    @Test
    func visibleResultSurvivesLargePaginationRegistration() async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$event") != nil }
        for index in 0..<600 {
            service.register(Self.textEvent(id: "$history-\(index)"))
        }
        #expect(service.presentation(roomID: Self.room, eventID: "$event") != nil)
        #expect(fixture.gateway.assists.count == 1)
    }
    
    @Test
    func classifierChangeAfterRestartCannotCreateAnotherPaidSlot() async throws {
        let fixture = try Fixture()
        let first = try fixture.makeService { _ in "und" }
        await first.connectIfNeeded()
        first.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { first.presentation(roomID: Self.room, eventID: "$event") != nil }
        first.invalidate()
        let second = try fixture.makeService { _ in "en" }
        await second.connectIfNeeded()
        second.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { second.availability == .unavailable }
        #expect(fixture.gateway.assists.count == 2)
        #expect(fixture.gateway.assists[0].operation != fixture.gateway.assists[1].operation)
        #expect(fixture.gateway.assists[0].requestId == fixture.gateway.assists[1].requestId)
        #expect(fixture.gateway.providerCalls == 1)
    }
    
    @Test
    func voiceReturningAfterAnUnpaidOffscreenDownloadStillStartsASROnce() async throws {
        let fixture = try Fixture()
        fixture.holdAudio = true
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        let owner = UUID()
        try service.show(Self.audioEvent(), owner: owner)
        try await Self.waitUntil { fixture.audioContinuation != nil }
        service.hide(roomID: Self.room, eventID: "$voice", owner: owner)
        fixture.releaseAudio()
        try await Self.waitUntil { fixture.audioReturned == 1 }
        await Task.yield()
        #expect(fixture.gateway.paidRequests.isEmpty)
        try service.show(Self.audioEvent(), owner: owner)
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$voice") != nil }
        #expect(fixture.gateway.transcriptions == 1)
        #expect(fixture.gateway.providerCalls == 1)
        #expect(service.availability == .ready)
    }

    @Test
    func exactPreclaimBusyRetriesAreBoundedAndReuseTheSameRequestID() async throws {
        let fixture = try Fixture()
        fixture.gateway.busyResponses = 3
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$event") != nil }
        #expect(fixture.retryDelays == [.milliseconds(500), .milliseconds(1500), .milliseconds(3000)])
        #expect(fixture.gateway.assists.count == 4)
        #expect(Set(fixture.gateway.assists.map(\.requestId)).count == 1)
        #expect(fixture.gateway.providerCalls == 1)
    }

    @Test
    func exhaustedPreclaimBusyDoesNotLeaveAPaidTombstoneAcrossRestart() async throws {
        let fixture = try Fixture()
        fixture.gateway.busyResponses = 4
        let first = try fixture.makeService()
        await first.connectIfNeeded()
        first.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { first.availability == .unavailable }
        #expect(fixture.gateway.assists.count == 4)
        #expect(fixture.gateway.providerCalls == 0)
        first.invalidate()
        let second = try fixture.makeService()
        await second.connectIfNeeded()
        second.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { second.presentation(roomID: Self.room, eventID: "$event") != nil }
        #expect(fixture.gateway.providerCalls == 1)
        #expect(fixture.gateway.assists.count == 5)
    }

    @Test
    func disablingDuringUnpaidBusyWaitDoesNotStartAnotherCall() async throws {
        let fixture = try Fixture()
        fixture.gateway.busyResponses = 1
        fixture.holdRetry = true
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { fixture.retryContinuation != nil }
        service.setConsent(false)
        fixture.releaseRetry()
        await Task.yield()
        #expect(fixture.gateway.assists.count == 1)
        #expect(fixture.gateway.providerCalls == 0)
        service.setConsent(true)
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$event") != nil }
        #expect(fixture.gateway.providerCalls == 1)
    }

    @Test(arguments: ["de", "es", "uk", "ja", "ar", "pt", "hi", "fil"])
    func allValidTargetLanguagesReachTheExistingService(_ language: String) async throws {
        let fixture = try Fixture()
        let service = try fixture.makeService()
        service.setLanguage(language)
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { !fixture.gateway.assists.isEmpty }
        #expect(service.language == language)
        #expect(fixture.gateway.assists.first?.targetLanguage == language)
    }

    @Test
    func completedLegacyWebResultIsReusedWithoutAPaidRequest() async throws {
        let fixture = try Fixture()
        fixture.gateway.cacheLookup = true
        fixture.gateway.cacheState = .ready
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$event") != nil }
        #expect(fixture.gateway.cacheQueries.count == 1)
        #expect(fixture.gateway.cacheQueries.first?.assist?.includeLegacyText == true)
        #expect(fixture.gateway.paidRequests.isEmpty)
        #expect(service.presentation(roomID: Self.room, eventID: "$event")?.text == "Existing account result")
        service.toggleOriginal(roomID: Self.room, eventID: "$event")
        #expect(service.presentation(roomID: Self.room, eventID: "$event") == nil)
    }

    @Test
    func sharedAudioCacheKeepsTranscriptWithoutASROrVoiceRewrite() async throws {
        let fixture = try Fixture()
        fixture.gateway.cacheLookup = true
        fixture.gateway.cacheState = .ready
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        try service.show(Self.audioEvent(), owner: UUID())
        try await Self.waitUntil { service.presentation(roomID: Self.room, eventID: "$voice") != nil }
        #expect(fixture.gateway.cacheQueries.first?.audioDigest != nil)
        #expect(fixture.gateway.paidRequests.isEmpty)
        #expect(service.presentation(roomID: Self.room, eventID: "$voice")?.originalTranscript == "Existing account result")
    }

    @Test
    func cacheFailureNeverFallsThroughToAPaidOperation() async throws {
        let fixture = try Fixture()
        fixture.gateway.cacheLookup = true
        fixture.gateway.failCache = true
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        service.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { service.availability == .unavailable }
        await service.refreshConnection()
        try await Self.waitUntil { fixture.gateway.cacheQueries.count == 2 }
        #expect(fixture.gateway.paidRequests.isEmpty)
        #expect(fixture.retryDelays.isEmpty)
    }

    @Test
    func uncertainLegacyCacheClaimBlocksNativePurchaseAfterRestart() async throws {
        let fixture = try Fixture()
        fixture.gateway.cacheLookup = true
        fixture.gateway.cacheState = .blocked
        let first = try fixture.makeService()
        await first.connectIfNeeded()
        first.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { fixture.gateway.cacheQueries.count == 1 }
        await Task.yield()
        first.invalidate()
        fixture.gateway.cacheState = .missing
        let second = try fixture.makeService()
        await second.connectIfNeeded()
        second.show(Self.textEvent(), owner: UUID())
        try await Self.waitUntil { fixture.gateway.cacheQueries.count == 2 }
        await Task.yield()
        #expect(fixture.gateway.paidRequests.isEmpty)
    }

    @Test
    func cacheMissUsesOptInNativeRoutesAndNeverCombinesVoiceText() async throws {
        let fixture = try Fixture()
        fixture.gateway.cacheLookup = true
        fixture.gateway.transcriptLanguage = "ru"
        let service = try fixture.makeService()
        await service.connectIfNeeded()
        try service.show(Self.audioEvent(), owner: UUID())
        try await Self.waitUntil { fixture.gateway.assists.count == 1 }
        #expect(fixture.gateway.assists.first?.includeLegacyText == false)
        #expect(fixture.gateway.cacheQueries.last?.assist?.includeLegacyText == false)
        guard case .transcribe(_, _, _, let reuseCache) = try #require(fixture.gateway.paidRequests.first) else {
            Issue.record("Expected native audio transcription")
            return
        }
        #expect(reuseCache)
    }

    private static let account = "@alice:chat.chiich.one"
    private static let room = "!room:chat.chiich.one"
    private static let originalEnglish = "This is the original incoming message written in English. Please make its meaning clear without changing the original message."
    
    private static func textEvent(id: String = "$event", sender: String = "@bob:chat.chiich.one", text: String = originalEnglish, revision: String? = nil) -> CHIICHReceiverAIEvent {
        .init(roomID: room, eventID: id, revision: revision ?? id, senderID: sender, content: .text(text))
    }
    
    private static func audioEvent(size: UInt = 1024) throws -> CHIICHReceiverAIEvent {
        let source = try MediaSourceProxy(url: #require(URL(string: "mxc://chat.chiich.one/synthetic-voice")), mimeType: "audio/ogg")
        return .init(roomID: room, eventID: "$voice", revision: "$voice", senderID: "@bob:chat.chiich.one", content: .audio(source, filename: "voice.ogg", byteCount: size))
    }
    
    private static func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(predicate())
    }
    
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = UUID().uuidString
        let preferences: UserDefaults
        let gateway = SyntheticGateway()
        var sessionActive = true
        var audioLoads = 0
        var audioReturned = 0
        var holdAudio = false
        var audioContinuation: CheckedContinuation<Void, Never>?
        var retryDelays: [Duration] = []
        var holdRetry = false
        var retryContinuation: CheckedContinuation<Void, Never>?

        func releaseAudio() {
            holdAudio = false
            audioContinuation?.resume()
            audioContinuation = nil
        }

        func releaseRetry() {
            holdRetry = false
            retryContinuation?.resume()
            retryContinuation = nil
        }
        
        init() throws {
            preferences = try #require(UserDefaults(suiteName: suite))
            // Most service tests model an already opted-in account upgrading with its old preference.
            // The default-off and migration tests remove or change the independent consent event.
            preferences.set(true, forKey: "chiich.receiver-ai." + CHIICHReceiverAIIdentity.hash([CHIICHReceiverAIServiceTests.account]) + ".enabled")
        }
        
        isolated deinit {
            try? FileManager.default.removeItem(at: directory)
            preferences.removePersistentDomain(forName: suite)
        }
        
        func makeService(detectLanguage: @escaping (String) -> String = CHIICHReceiverAILanguage.detect) throws -> CHIICHReceiverAIService {
            let service = try CHIICHReceiverAIService(accountID: CHIICHReceiverAIServiceTests.account,
                                                      request: { [gateway] in await gateway.request($0, source: $1) },
                                                      loadAudio: { [weak self] _, _ in
                                                          guard let self else { return .failure(.unavailable) }
                                                          audioLoads += 1
                                                          if holdAudio { await withCheckedContinuation { audioContinuation = $0 } }
                                                          audioReturned += 1
                                                          return .success(Data([1, 2, 3]))
                                                      },
                                                      sessionIsCurrent: { [weak self] in self?.sessionActive == true },
                                                      claims: CHIICHReceiverAIClaimStore(accountID: CHIICHReceiverAIServiceTests.account, directory: directory),
                                                      preferences: preferences,
                                                      detectLanguage: detectLanguage,
                                                      retryDelay: { [weak self] delay in
                                                          guard let self else { throw CHIICHReceiverAIError.cancelled }
                                                          retryDelays.append(delay)
                                                          if holdRetry { await withCheckedContinuation { retryContinuation = $0 } }
                                                          try Task.checkCancellation()
                                                      })
            service.setLanguage("en")
            return service
        }
    }
    
    private final class SyntheticGateway {
        var consent: Bool? = true
        var consentVersion = 1
        var failConsentWrite = false
        var failConsentRead = false
        var consentWrites: [Bool] = []
        var contexts: [CHIICHReceiverAISourceContext] = []
        var configured = true
        var failAssist = false
        var holdAssist = false
        var busyResponses = 0
        var cacheLookup = false
        var cacheState = CHIICHReceiverAICacheResponse.State.missing
        var failCache = false
        var cacheQueries: [CHIICHReceiverAICacheQuery] = []
        var transcriptLanguage = "en"
        var transcript = "This is the unmodified original voice transcript."
        var paidRequests: [CHIICHReceiverAIRequest] = []
        var providerCalls = 0
        var cache: [String: Data] = [:]
        var payloads: [String: String] = [:]
        var continuation: CheckedContinuation<Void, Never>?
        var assists: [CHIICHReceiverAIAssist] {
            paidRequests.compactMap {
                if case .assist(let payload) = $0 {
                    payload
                } else {
                    nil
                }
            }
        }
        
        var transcriptions: Int {
            paidRequests.filter {
                if case .transcribe = $0 {
                    true
                } else {
                    false
                }
            }.count
        }
        
        func request(_ request: CHIICHReceiverAIRequest, source: CHIICHReceiverAISourceContext?) async -> Result<Data, CHIICHReceiverAIError> {
            switch request {
            case .readConsent:
                if failConsentRead { return .failure(.unavailable) }
                guard let consent else { return .failure(.accountDataMissing) }
                return .success(Self.json(["version": 1, "enabled": consent]))
            case .writeConsent(_, let enabled):
                consentWrites.append(enabled)
                guard !failConsentWrite else { return .failure(.unavailable) }
                consent = enabled
                return .success(Self.json([:]))
            default: break
            }
            if case .status = request {
                return .success(Self.json(["policy": "receiver-v1", "configured": configured, "enabled": configured, "capabilities": ["text": configured, "audio": configured, "cacheLookup": cacheLookup, "consentVersion": consentVersion]]))
            }
            guard consent == true, let source else { return .failure(.consentRequired) }
            contexts.append(source)
            if case .cache(let query) = request {
                cacheQueries.append(query)
                if failCache { return .failure(.unavailable) }
                var body: [String: Any] = ["requestId": query.requestId, "state": cacheState.rawValue]
                if cacheState == .ready {
                    body["result"] = ["requestId": query.requestId, "text": "Existing account result", "language": "en"]
                }
                return .success(Self.json(body))
            }
            paidRequests.append(request)
            if busyResponses > 0 {
                busyResponses -= 1
                return .failure(.preclaimBusy)
            }
            let identifier: String
            let text: String
            let language: String?
            let digest: String
            switch request {
            case .assist(let payload):
                identifier = payload.requestId
                digest = CHIICHReceiverAIIdentity.hash([payload.operation.rawValue, payload.text, payload.sourceLanguage, payload.targetLanguage])
                if holdAssist {
                    await withCheckedContinuation { continuation = $0 }
                }
                if failAssist {
                    return .failure(.uncertain)
                }
                text = "Processed original"
                language = nil
            case .transcribe(let requestID, _, _, _):
                identifier = requestID
                digest = "synthetic-audio"
                text = transcript
                language = transcriptLanguage
            case .status, .cache, .readConsent, .writeConsent: return .failure(.invalidRequest)
            }
            if let cached = cache[identifier] {
                guard payloads[identifier] == digest else { return .failure(.unavailable) }
                return .success(cached)
            }
            providerCalls += 1
            var body: [String: Any] = ["requestId": identifier, "text": text]
            if let language {
                body["language"] = language
            }
            let result = Self.json(body)
            cache[identifier] = result
            payloads[identifier] = digest
            return .success(result)
        }
        
        func releaseAssist() {
            holdAssist = false
            continuation?.resume()
            continuation = nil
        }
        
        private static func json(_ object: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
    }
}
