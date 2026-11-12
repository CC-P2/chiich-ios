// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import CryptoKit
import Foundation
import NaturalLanguage

nonisolated enum CHIICHReceiverAIError: Error, Equatable {
    case unavailable, invalidRequest, invalidResponse, uncertain, alreadyAttempted, cancelled, storageUnavailable
    case preclaimBusy, consentRequired, accountDataMissing
    case matrixUnknownToken(softLogout: Bool)
}

nonisolated enum CHIICHReceiverAIOperation: String, Codable, Sendable {
    case rewrite, translate
    case rewriteOrTranslate = "rewrite_or_translate"
}

nonisolated struct CHIICHReceiverAIAssist: Codable, Sendable {
    let operation: CHIICHReceiverAIOperation
    let text: String
    let requestId: String
    let sourceLanguage: String
    let targetLanguage: String
    var includeLegacyText: Bool?
}

nonisolated struct CHIICHReceiverAISourceContext: Equatable, Sendable {
    let roomID: String
    let eventID: String
    var transcriptRequestID: String?

    func queryItems() throws -> [URLQueryItem] {
        guard roomID.hasPrefix("!"), eventID.hasPrefix("$"),
              roomID.utf8.count <= 255, eventID.utf8.count <= 255 else { throw CHIICHReceiverAIError.invalidRequest }
        var items = [URLQueryItem(name: "roomId", value: roomID), URLQueryItem(name: "eventId", value: eventID)]
        if let transcriptRequestID {
            guard CHIICHReceiverAIRequest.validID(transcriptRequestID) else { throw CHIICHReceiverAIError.invalidRequest }
            items.append(URLQueryItem(name: "transcriptRequestId", value: transcriptRequestID))
        }
        return items
    }
}

nonisolated enum CHIICHReceiverAIRequest: Sendable {
    case status
    case readConsent(String)
    case writeConsent(String, Bool)
    case cache(CHIICHReceiverAICacheQuery)
    case assist(CHIICHReceiverAIAssist)
    case transcribe(requestID: String, data: Data, mimeType: String, reuseCache: Bool = false)
    
    static let audioLimit = 25_000_000
    static let mimeTypes: Set = ["audio/mpeg", "audio/mp3", "audio/mp4", "audio/x-m4a", "audio/wav", "audio/x-wav", "audio/webm", "audio/ogg", "audio/flac", "video/mp4", "video/webm"]
    
    var consentAccount: String? {
        switch self {
        case .readConsent(let account), .writeConsent(let account, _): account
        default: nil
        }
    }

    func urlRequest(homeserver: String, source: CHIICHReceiverAISourceContext? = nil) throws -> URLRequest {
        guard let components = URLComponents(string: homeserver),
              components.scheme == "https", components.user == nil, components.password == nil,
              components.port == nil || components.port == 443,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              let host = components.host, ["matrix.chiich.one", "chiich-matrix.onrender.com"].contains(host) else {
            throw CHIICHReceiverAIError.invalidRequest
        }
        if let account = consentAccount {
            guard source == nil, account.hasPrefix("@"), account.utf8.count <= 255,
                  let encoded = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
                  let url = URL(string: "https://\(host)/_matrix/client/v3/user/\(encoded)/account_data/\(CHIICHReceiverAIConsent.eventType)")
            else { throw CHIICHReceiverAIError.invalidRequest }
            var result = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            result.setValue("application/json", forHTTPHeaderField: "Accept")
            if case .writeConsent(_, let enabled) = self {
                result.httpMethod = "PUT"
                result.httpBody = try JSONEncoder().encode(CHIICHReceiverAIConsent.Record(enabled: enabled))
                result.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            return result
        }
        let route: String
        let body: Data?
        let mimeType: String?
        switch self {
        case .readConsent, .writeConsent:
            throw CHIICHReceiverAIError.invalidRequest
        case .status:
            guard source == nil else { throw CHIICHReceiverAIError.invalidRequest }
            route = "status"
            body = nil
            mimeType = nil
        case .cache(let query):
            try query.validate()
            route = "cache"
            body = try JSONEncoder().encode(query)
            mimeType = "application/json"
        case .assist(let payload):
            guard Self.validID(payload.requestId),
                  !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  payload.text.utf16.count <= 12000,
                  CHIICHReceiverAILanguage.valid(payload.sourceLanguage),
                  CHIICHReceiverAILanguage.validTarget(payload.targetLanguage) else {
                throw CHIICHReceiverAIError.invalidRequest
            }
            route = "assist"
            body = try JSONEncoder().encode(payload)
            mimeType = "application/json"
        case .transcribe(let requestID, let data, let type, let reuseCache):
            guard Self.validID(requestID), !data.isEmpty, data.count <= Self.audioLimit,
                  Self.mimeTypes.contains(type) else { throw CHIICHReceiverAIError.invalidRequest }
            route = "\(reuseCache ? "transcribe-shared" : "transcribe")/\(requestID)"
            body = data
            mimeType = type
        }
        var destination = components
        destination.path = "/_synapse/client/chiich/receiver-ai/" + route
        if let source {
            destination.queryItems = try source.queryItems()
            destination.percentEncodedQuery = destination.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        } else if route != "status" {
            throw CHIICHReceiverAIError.invalidRequest
        }
        guard let url = destination.url else {
            throw CHIICHReceiverAIError.invalidRequest
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: body == nil ? 8 : 45)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue(mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    
    static func validID(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

nonisolated struct CHIICHReceiverAIStatus: Decodable, Sendable {
    struct Capabilities: Decodable, Sendable {
        let text: Bool
        let audio: Bool
        let cacheLookup: Bool?
        let consentVersion: Int?
    }
    
    let policy: String
    let configured: Bool
    let enabled: Bool
    let capabilities: Capabilities
    var isAvailable: Bool {
        policy == "receiver-v1" && configured && enabled && capabilities.text && capabilities.consentVersion == CHIICHReceiverAIConsent.Record.currentVersion
    }
}

nonisolated struct CHIICHReceiverAIResponse: Decodable, Sendable {
    let requestId: String
    let text: String
    let language: String?
    
    func validated(for requestID: String) throws -> Self {
        guard requestId == requestID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf16.count <= 24000 else { throw CHIICHReceiverAIError.invalidResponse }
        return self
    }
}

nonisolated enum CHIICHReceiverAILanguage {
    static func normalize(_ language: String) -> String {
        language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? "und"
    }
    
    static func valid(_ language: String) -> Bool {
        language == "und" || language.range(of: "^[a-z]{2,3}(-[a-z0-9]{2,8})*$", options: .regularExpression) != nil
    }

    static func validTarget(_ language: String) -> Bool {
        language != "und" && valid(language)
    }
    
    static func detect(_ text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first,
              confidence >= 0.8 else { return "und" }
        return normalize(language.rawValue)
    }
    
    static func operation(source: String, target: String) -> CHIICHReceiverAIOperation {
        source == "und" ? .rewriteOrTranslate : source == target ? .rewrite : .translate
    }
}

nonisolated enum CHIICHReceiverAIIdentity {
    static func hash(_ values: [String]) -> String {
        // A fixed array encoding keeps request IDs stable across scroll, restart and devices.
        let data = (try? JSONSerialization.data(withJSONObject: values, options: [.withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    
    static func event(accountID: String, roomID: String, eventID: String) -> String {
        hash(["chiich-receiver-ios-v1", accountID, roomID, eventID])
    }
    
    static func request(source: String, operation: String, language: String) -> String {
        hash(["chiich-receiver-ios-v1", source, operation, language])
    }
}

nonisolated struct CHIICHReceiverAIEvent: Sendable {
    enum Content: Sendable {
        case text(String)
        case audio(MediaSourceProxy, filename: String, byteCount: UInt?)
    }
    
    let roomID: String
    let eventID: String
    let revision: String
    let senderID: String
    let content: Content
    var revisionTimestamp: Int64 = 0
    
    var contentFingerprint: String {
        switch content {
        case .text(let text): CHIICHReceiverAIIdentity.hash(["text", text])
        case .audio(let source, _, _): CHIICHReceiverAIIdentity.hash(["audio", source.url?.absoluteString ?? ""])
        }
    }
    
    func identity(accountID: String) -> String {
        CHIICHReceiverAIIdentity.event(accountID: accountID, roomID: roomID, eventID: eventID)
    }
    
    func source(accountID: String) -> String {
        let signature: [String]
        switch content {
        case .text(let text): signature = ["text", text]
        case .audio(let source, _, let byteCount): signature = ["audio", source.url?.absoluteString ?? "", source.mimeType ?? "", byteCount.map(String.init) ?? ""]
        }
        return CHIICHReceiverAIIdentity.hash([identity(accountID: accountID), revision] + signature)
    }
}

nonisolated struct CHIICHReceiverAIPresentation: Sendable {
    let text: String
    let originalTranscript: String?
    var canShowOriginal: Bool {
        originalTranscript == nil || originalTranscript != text
    }
}
