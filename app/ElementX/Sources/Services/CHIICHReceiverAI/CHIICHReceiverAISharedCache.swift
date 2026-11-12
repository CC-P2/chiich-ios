// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import CryptoKit
import Foundation

/// A read-only query of the existing account's encrypted result ledger. It never creates a paid claim.
/// Native request IDs stay unchanged so older installed builds' uncertain claims remain authoritative.
nonisolated struct CHIICHReceiverAICacheQuery: Encodable, Sendable {
    let requestId: String
    let assist: CHIICHReceiverAIAssist?
    let audioDigest: String?

    init(assist: CHIICHReceiverAIAssist, includeLegacyText: Bool) {
        requestId = assist.requestId
        var payload = assist
        payload.includeLegacyText = includeLegacyText
        self.assist = payload
        audioDigest = nil
    }

    init(requestID: String, audio: Data, mimeType: String) {
        requestId = requestID
        assist = nil
        var hash = SHA256()
        hash.update(data: Data(("receiver-v1\0transcribe\0" + mimeType + "\0").utf8))
        hash.update(data: audio)
        audioDigest = hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func validate() throws {
        guard CHIICHReceiverAIRequest.validID(requestId) else { throw CHIICHReceiverAIError.invalidRequest }
        if let assist {
            guard assist.requestId == requestId, audioDigest == nil, assist.includeLegacyText != nil,
                  CHIICHReceiverAILanguage.valid(assist.sourceLanguage), CHIICHReceiverAILanguage.validTarget(assist.targetLanguage),
                  !assist.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, assist.text.utf16.count <= 12000 else {
                throw CHIICHReceiverAIError.invalidRequest
            }
        } else {
            guard let audioDigest, CHIICHReceiverAIRequest.validID(audioDigest) else {
                throw CHIICHReceiverAIError.invalidRequest
            }
        }
    }
}

nonisolated struct CHIICHReceiverAICacheResponse: Decodable, Sendable {
    enum State: String, Decodable, Sendable { case ready, missing, blocked }
    let requestId: String
    let state: State
    let result: CHIICHReceiverAIResponse?

    func validated(for requestID: String) throws -> Self {
        guard requestId == requestID else { throw CHIICHReceiverAIError.invalidResponse }
        if state == .ready {
            guard let result else { throw CHIICHReceiverAIError.invalidResponse }
            _ = try result.validated(for: requestID)
        } else if result != nil {
            throw CHIICHReceiverAIError.invalidResponse
        }
        return self
    }
}
