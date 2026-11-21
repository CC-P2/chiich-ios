// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

enum CHIICHPasswordHTTP {
    static let maximumResponseBytes = 64_000

    /// One explicit submission only. A transport failure must never automatically repeat a password change.
    static func send(_ request: URLRequest) async -> Result<CHIICHPasswordResponse, CHIICHPasswordError> {
        await send(request, classifier: classify)
    }

    static func sendDeletion(_ request: URLRequest) async -> Result<CHIICHPasswordResponse, CHIICHPasswordError> {
        await send(request, classifier: CHIICHDeletionResponse.classify)
    }

    static func send<Value>(_ request: URLRequest,
                            classifier: (Data, Int) -> Result<Value, CHIICHPasswordError>) async -> Result<Value, CHIICHPasswordError> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 35
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: CHIICHPasswordRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == request.url,
                  response.expectedContentLength <= maximumResponseBytes else { return .failure(.outcomeUnknown) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else { return .failure(.outcomeUnknown) }
                data.append(byte)
            }
            try Task.checkCancellation()
            return classifier(data, response.statusCode)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(.outcomeUnknown)
        }
    }

    static func classify(data: Data, statusCode: Int) -> Result<CHIICHPasswordResponse, CHIICHPasswordError> {
        guard data.count <= maximumResponseBytes else { return .failure(.outcomeUnknown) }
        let error = try? JSONDecoder().decode(MatrixError.self, from: data)
        if statusCode == 401, error?.errcode == "M_UNKNOWN_TOKEN" {
            return .failure(.matrixUnknownToken(softLogout: error?.softLogout ?? false))
        }
        if statusCode == 401 {
            guard let challenge = try? JSONDecoder().decode(CHIICHPasswordChallenge.self, from: data), challenge.isValid else {
                return .failure(.invalidResponse)
            }
            return .success(.challenge(challenge))
        }
        if statusCode == 200 {
            guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  result["errcode"] == nil, result["flows"] == nil else { return .failure(.outcomeUnknown) }
            return .success(.success)
        }
        if statusCode == 429 { return .failure(.rateLimited) }
        if statusCode == 404 || statusCode == 405 { return .failure(.unsupportedServer) }
        if statusCode == 403 { return .failure(.authenticationRejected) }
        if statusCode == 400, let code = error?.errcode,
           code == "M_WEAK_PASSWORD" || code.hasPrefix("M_PASSWORD_") {
            return .failure(.passwordPolicy)
        }
        if (400...499).contains(statusCode) { return .failure(.invalidResponse) }
        return .failure(.outcomeUnknown)
    }

    private nonisolated struct MatrixError: Decodable {
        enum CodingKeys: String, CodingKey {
            case errcode
            case softLogout = "soft_logout"
        }

        let errcode: String
        let softLogout: Bool?
    }
}

private final nonisolated class CHIICHPasswordRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
