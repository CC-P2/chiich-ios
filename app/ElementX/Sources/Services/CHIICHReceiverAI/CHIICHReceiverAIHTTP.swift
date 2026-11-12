// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

/// The SDK has no generic authenticated Synapse-module request API in 26.10.24.
enum CHIICHReceiverAIHTTP {
    static func send(_ request: URLRequest) async -> Result<Data, CHIICHReceiverAIError> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 50
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: CHIICHReceiverAIRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == request.url,
                  response.expectedContentLength <= 200_000 else {
                return .failure(.unavailable)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 200_000 else { return .failure(.invalidResponse) }
                data.append(byte)
            }
            try Task.checkCancellation()
            return classify(data: data, statusCode: response.statusCode)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.uncertain)
        }
    }
    
    static func classify(data: Data, statusCode: Int) -> Result<Data, CHIICHReceiverAIError> {
        guard data.count <= 200_000 else { return .failure(.invalidResponse) }
        // The owned gateway certifies this exact response before creating a paid claim.
        // No other 429, provider failure, malformed response or uncertain transport is retryable.
        if statusCode == 429,
           let error = try? JSONDecoder().decode(PreclaimBusyError.self, from: data),
           error.errcode == "M_CHIICH_AI_AI_BUSY", error.error == "AI_BUSY", error.retryable {
            return .failure(.preclaimBusy)
        }
        if let error = try? JSONDecoder().decode(MatrixAuthenticationError.self, from: data) {
            if statusCode == 404, error.errcode == "M_NOT_FOUND" { return .failure(.accountDataMissing) }
            if statusCode == 403, ["M_CHIICH_AI_CONSENT_REQUIRED", "M_CHIICH_AI_SOURCE_UNAVAILABLE"].contains(error.errcode) {
                return .failure(.consentRequired)
            }
        }
        if statusCode == 401,
           let error = try? JSONDecoder().decode(MatrixAuthenticationError.self, from: data), error.errcode == "M_UNKNOWN_TOKEN" {
            return .failure(.matrixUnknownToken(softLogout: error.softLogout ?? false))
        }
        guard (200...299).contains(statusCode) else { return .failure(.unavailable) }
        return .success(data)
    }
    
    private nonisolated struct MatrixAuthenticationError: Decodable {
        enum CodingKeys: String, CodingKey {
            case errcode
            case softLogout = "soft_logout"
        }
        
        let errcode: String
        let softLogout: Bool?
    }

    private nonisolated struct PreclaimBusyError: Decodable {
        let errcode: String
        let error: String
        let retryable: Bool
    }
}

private final nonisolated class CHIICHReceiverAIRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
