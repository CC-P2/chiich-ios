// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

/// The pinned SDK has no authenticated Synapse-module request API.
enum CHIICHIdentityHTTP {
    static let responseLimit = 16_384

    static func send(_ request: URLRequest) async -> Result<Data, CHIICHIdentityError> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: CHIICHIdentityRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == request.url,
                  response.expectedContentLength <= Int64(responseLimit) else { return .failure(.invalidResponse) }
            var data = Data()
            for try await byte in bytes {
                guard data.count < responseLimit else { return .failure(.invalidResponse) }
                data.append(byte)
            }
            try Task.checkCancellation()
            return classify(data: data, statusCode: response.statusCode)
        } catch is CancellationError {
            return .failure(.cancelled)
        } catch {
            return .failure(Task.isCancelled ? .cancelled : .uncertain)
        }
    }

    static func classify(data: Data, statusCode: Int) -> Result<Data, CHIICHIdentityError> {
        guard data.count <= responseLimit else { return .failure(.invalidResponse) }
        if statusCode == 200 { return .success(data) }
        let response = try? JSONDecoder().decode(MatrixError.self, from: data)
        switch (statusCode, response?.errcode) {
        case (401, "M_UNKNOWN_TOKEN"):
            return .failure(.matrixUnknownToken(softLogout: response?.softLogout ?? false))
        case (400, "M_INVALID_PARAM"):
            return .failure(.invalidUsername)
        case (400, "M_USERNAME_LIMIT_EXCEEDED"):
            return .failure(.aliasLimit)
        case (409, "M_CONFLICT"):
            return .failure(.conflict)
        case (429, "M_LIMIT_EXCEEDED"):
            return .failure(.rateLimited)
        case (404, "M_NOT_FOUND"):
            return .failure(.notFound)
        default:
            return .failure(.unavailable)
        }
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

private final nonisolated class CHIICHIdentityRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
