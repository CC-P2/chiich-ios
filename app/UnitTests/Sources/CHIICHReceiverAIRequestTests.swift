// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import Testing

struct CHIICHReceiverAIRequestTests {
    @Test
    func chiichPrivacyPolicyIsPublicAndSeparateFromTerms() {
        let settings = AppSettings.volatile()
        #expect(settings.privacyURL.scheme == "https")
        #expect(settings.privacyURL.host == "chiich.one")
        #expect(["/help/privacy.html", "/help/privacy-en.html"].contains(settings.privacyURL.path))
        #expect(settings.acceptableUseURL != settings.privacyURL)
    }

    private var source: CHIICHReceiverAISourceContext {
        .init(roomID: "!room:chat.chiich.one", eventID: "$edit+abc/xyz")
    }

    @Test
    func contentQueriesCarryOnlySourceIdentifiers() throws {
        let identifier = String(repeating: "1", count: 64)
        let payload = CHIICHReceiverAIAssist(operation: .rewrite, text: "private", requestId: identifier, sourceLanguage: "en", targetLanguage: "en")
        let request = CHIICHReceiverAIRequest.assist(payload)
        #expect(throws: CHIICHReceiverAIError.self) { try request.urlRequest(homeserver: "https://matrix.chiich.one") }
        var context = source
        context.transcriptRequestID = identifier
        let url = try #require(request.urlRequest(homeserver: "https://matrix.chiich.one", source: context).url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedQuery?.contains("%2B") == true)
        #expect(components.queryItems == [.init(name: "roomId", value: source.roomID), .init(name: "eventId", value: source.eventID),
                                         .init(name: "transcriptRequestId", value: identifier)])
    }

    @Test
    func explicitConsentUsesDedicatedAccountDataAndVersion() throws {
        let request = try CHIICHReceiverAIRequest.writeConsent("@alice:chat.chiich.one", true).urlRequest(homeserver: "https://matrix.chiich.one")
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.path == "/_matrix/client/v3/user/@alice:chat.chiich.one/account_data/one.chiich.receiver_ai.consent")
        let record = try JSONDecoder().decode(CHIICHReceiverAIConsent.Record.self, from: #require(request.httpBody))
        #expect(record.version == 1 && record.enabled)
    }

    @Test
    func sourceOrConsentDenialIsMessageSpecific() throws {
        for code in ["M_CHIICH_AI_SOURCE_UNAVAILABLE", "M_CHIICH_AI_CONSENT_REQUIRED"] {
            let data = try JSONSerialization.data(withJSONObject: ["errcode": code])
            #expect(CHIICHReceiverAIHTTP.classify(data: data, statusCode: 403) == .failure(.consentRequired))
        }
    }

    @Test(arguments: ["https://matrix.chiich.one", "https://chiich-matrix.onrender.com/"])
    func statusUsesExistingSynapseOrigin(_ origin: String) throws {
        let request = try CHIICHReceiverAIRequest.status.urlRequest(homeserver: origin)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/_synapse/client/chiich/receiver-ai/status")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }
    
    @Test(arguments: ["http://matrix.chiich.one", "https://evil.invalid", "https://matrix.chiich.one.evil.invalid",
                      "https://matrix.chiich.one/path", "https://matrix.chiich.one?to=evil", "https://matrix.chiich.one#fragment",
                      "https://user@matrix.chiich.one", "https://matrix.chiich.one:8448"])
    func rejectsUntrustedOrigin(_ origin: String) {
        #expect(throws: CHIICHReceiverAIError.self) {
            try CHIICHReceiverAIRequest.status.urlRequest(homeserver: origin)
        }
    }
    
    @Test
    func assistContractHasOnlyExpectedFields() throws {
        let identifier = String(repeating: "a", count: 64)
        let payload = CHIICHReceiverAIAssist(operation: .translate, text: "Исходное сообщение", requestId: identifier, sourceLanguage: "ru", targetLanguage: "en")
        let request = try CHIICHReceiverAIRequest.assist(payload).urlRequest(homeserver: "https://matrix.chiich.one", source: source)
        let requestBody = try #require(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: requestBody)
        let body = try #require(object as? [String: String])
        #expect(Set(body.keys) == ["operation", "text", "requestId", "sourceLanguage", "targetLanguage"])
        #expect(body["text"] == "Исходное сообщение")
        #expect(body["operation"] == "translate")
        #expect(request.httpMethod == "POST")
    }
    
    @Test
    func invalidOrOversizedTextNeverGetsARequest() {
        for text in ["", "   ", String(repeating: "x", count: 12001)] {
            let payload = CHIICHReceiverAIAssist(operation: .rewrite, text: text, requestId: String(repeating: "b", count: 64), sourceLanguage: "en", targetLanguage: "en")
            #expect(throws: CHIICHReceiverAIError.self) {
                try CHIICHReceiverAIRequest.assist(payload).urlRequest(homeserver: "https://matrix.chiich.one", source: source)
            }
        }
    }
    
    @Test
    func audioUsesRawBodyAndRequestIDPath() throws {
        let identifier = String(repeating: "c", count: 64)
        let data = Data([1, 2, 3])
        let request = try CHIICHReceiverAIRequest.transcribe(requestID: identifier, data: data, mimeType: "audio/ogg").urlRequest(homeserver: "https://matrix.chiich.one", source: source)
        #expect(request.url?.path == "/_synapse/client/chiich/receiver-ai/transcribe/" + identifier)
        #expect(request.httpBody == data)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "audio/ogg")
        #expect(throws: CHIICHReceiverAIError.self) {
            try CHIICHReceiverAIRequest.transcribe(requestID: identifier, data: data, mimeType: "application/pdf").urlRequest(homeserver: "https://matrix.chiich.one", source: source)
        }
    }
    
    @Test
    func receivedRequestIdentityAndLimitsAreValidated() throws {
        let identifier = String(repeating: "d", count: 64)
        #expect(throws: CHIICHReceiverAIError.self) {
            try CHIICHReceiverAIResponse(requestId: "wrong", text: "result", language: nil).validated(for: identifier)
        }
        #expect(throws: CHIICHReceiverAIError.self) {
            try CHIICHReceiverAIResponse(requestId: identifier, text: String(repeating: "x", count: 24001), language: nil).validated(for: identifier)
        }
        let response = try CHIICHReceiverAIResponse(requestId: identifier, text: "result", language: nil).validated(for: identifier)
        #expect(response.text == "result")
    }
    
    @Test
    func policyDoesNotTranslateRewrittenText() {
        #expect(CHIICHReceiverAILanguage.operation(source: "ru", target: "ru") == .rewrite)
        #expect(CHIICHReceiverAILanguage.operation(source: "zh", target: "ru") == .translate)
        #expect(CHIICHReceiverAILanguage.operation(source: "und", target: "en") == .rewriteOrTranslate)
    }
    
    @Test
    func requestIDsAreStableAndIsolateAllIdentityComponents() {
        let event = CHIICHReceiverAIEvent(roomID: "!room:chat.chiich.one", eventID: "$event", revision: "$edit", senderID: "@bob:chat.chiich.one", content: .text("Исходный текст 中文"))
        let source = event.source(accountID: "@alice:chat.chiich.one")
        #expect(source == event.source(accountID: "@alice:chat.chiich.one"))
        #expect(source != event.source(accountID: "@other:chat.chiich.one"))
        let edited = CHIICHReceiverAIEvent(roomID: event.roomID, eventID: event.eventID, revision: "$newedit", senderID: event.senderID, content: event.content)
        #expect(source != edited.source(accountID: "@alice:chat.chiich.one"))
        let otherRoom = CHIICHReceiverAIEvent(roomID: "!different:chat.chiich.one", eventID: event.eventID, revision: event.revision, senderID: event.senderID, content: event.content)
        #expect(source != otherRoom.source(accountID: "@alice:chat.chiich.one"))
        let rewrite = CHIICHReceiverAIIdentity.request(source: source, operation: "rewrite", language: "ru:ru")
        #expect(rewrite != CHIICHReceiverAIIdentity.request(source: source, operation: "translate", language: "ru:en"))
        #expect(rewrite != CHIICHReceiverAIIdentity.request(source: source, operation: "rewrite", language: "en:en"))
        #expect(CHIICHReceiverAIRequest.validID(rewrite))
    }
    
    @Test(arguments: [true, false])
    func exactUnknownTokenPreservesNativeSoftLogout(_ softLogout: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: ["errcode": "M_UNKNOWN_TOKEN", "soft_logout": softLogout])
        guard case .failure(let error) = CHIICHReceiverAIHTTP.classify(data: data, statusCode: 401) else {
            Issue.record("Expected the exact Matrix authentication failure")
            return
        }
        #expect(error == .matrixUnknownToken(softLogout: softLogout))
    }
    
    @Test(arguments: [403, 429, 500])
    func otherHTTPStatusesNeverTriggerMatrixLogout(_ status: Int) {
        let data = Data(#"{"errcode":"M_UNKNOWN_TOKEN","soft_logout":true}"#.utf8)
        guard case .failure(let error) = CHIICHReceiverAIHTTP.classify(data: data, statusCode: status) else {
            Issue.record("Unexpected successful HTTP status classification")
            return
        }
        #expect(error == .unavailable)
    }
    
    @Test(arguments: [#"{"errcode":"M_FORBIDDEN"}"#, #"{"errcode":"M_CHIICH_AI_PROVIDER_AUTH_ERROR"}"#, #"{"errcode":"M_UNKNOWN_TOKEN","soft_logout":"true"}"#, "not json"])
    func otherAuthResponsesRemainAIOnlyFailures(_ json: String) {
        guard case .failure(let error) = CHIICHReceiverAIHTTP.classify(data: Data(json.utf8), statusCode: 401) else {
            Issue.record("Unexpected successful authentication error classification")
            return
        }
        #expect(error == .unavailable)
    }
    
    @Test
    func onlyExactAuthenticatedPreclaimBusyIsRetryable() {
        let success = Data(#"{"errcode":"M_CHIICH_AI_AI_BUSY","error":"AI_BUSY","retryable":true}"#.utf8)
        if case .failure(let error) = CHIICHReceiverAIHTTP.classify(data: success, statusCode: 429) {
            #expect(error == .preclaimBusy)
        } else { Issue.record("Expected certified unpaid busy response") }
        for body in [
            #"{"errcode":"M_CHIICH_AI_AI_BUSY","error":"AI_BUSY","retryable":false}"#,
            #"{"errcode":"M_CHIICH_AI_AI_BUSY","error":"AI_BUSY","retryable":"true"}"#,
            #"{"errcode":"M_CHIICH_AI_RATE_LIMIT","error":"RATE_LIMIT","retryable":true}"#,
            #"{"errcode":"M_CHIICH_AI_AI_BUSY","error":"provider detail","retryable":true}"#,
            #"{"errcode":"M_CHIICH_AI_AI_BUSY","error":"AI_BUSY"}"#
        ] {
            if case .failure(let error) = CHIICHReceiverAIHTTP.classify(data: Data(body.utf8), statusCode: 429) {
                #expect(error == .unavailable)
            } else { Issue.record("Unexpected successful error response") }
        }
        if case .failure(let error) = CHIICHReceiverAIHTTP.classify(data: success, statusCode: 503) {
            #expect(error == .unavailable)
        } else { Issue.record("Wrong HTTP status cannot certify unpaid retry") }
    }

    @Test
    func sharedAudioFingerprintMatchesTheReleasedPythonGateway() throws {
        let identifier = String(repeating: "f", count: 64)
        let audio = Data([1, 2, 3])
        let query = CHIICHReceiverAICacheQuery(requestID: identifier, audio: audio, mimeType: "audio/ogg")
        #expect(query.audioDigest == "40a3b66976bb5d8dbb3f8b1a88e6e77c2309807692f7fed1d44e0f7ae3a1dbd0")
        let request = try CHIICHReceiverAIRequest.cache(query).urlRequest(homeserver: "https://matrix.chiich.one", source: source)
        #expect(request.url?.path == "/_synapse/client/chiich/receiver-ai/cache")
        let object = try JSONSerialization.jsonObject(with: #require(request.httpBody))
        let body = try #require(object as? [String: String])
        #expect(Set(body.keys) == ["requestId", "audioDigest"])
        let shared = try CHIICHReceiverAIRequest.transcribe(requestID: identifier, data: audio, mimeType: "audio/ogg", reuseCache: true)
            .urlRequest(homeserver: "https://matrix.chiich.one", source: source)
        #expect(shared.url?.path == "/_synapse/client/chiich/receiver-ai/transcribe-shared/" + identifier)
        #expect(shared.httpBody == audio)
    }

    @Test
    func malformedCacheResponsesCannotBecomePaidFallbackOrDisplayedContent() throws {
        let identifier = String(repeating: "d", count: 64)
        for body in [
            #"{"requestId":"wrong","state":"missing"}"#,
            #"{"requestId":"\#(identifier)","state":"ready"}"#,
            #"{"requestId":"\#(identifier)","state":"missing","result":{"requestId":"\#(identifier)","text":"bad"}}"#
        ] {
            #expect(throws: Error.self) {
                try JSONDecoder().decode(CHIICHReceiverAICacheResponse.self, from: Data(body.utf8)).validated(for: identifier)
            }
        }
    }

    @Test
    func interruptedClaimSurvivesRestartAndNeverEvictsToRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identifier = String(repeating: "e", count: 64)
        let store = try CHIICHReceiverAIClaimStore(accountID: "@alice:chat.chiich.one", directory: directory, limit: 1)
        try store.claim(identifier)
        let restored = try CHIICHReceiverAIClaimStore(accountID: "@alice:chat.chiich.one", directory: directory, limit: 1)
        #expect(restored.contains(identifier))
        #expect(throws: CHIICHReceiverAIError.self) { try restored.claim(identifier) }
        #expect(throws: CHIICHReceiverAIError.self) { try restored.claim(String(repeating: "f", count: 64)) }
        let other = try CHIICHReceiverAIClaimStore(accountID: "@other:chat.chiich.one", directory: directory)
        #expect(!other.contains(identifier))
        try restored.complete(identifier)
        #expect(!restored.contains(identifier))
    }
}
