//
// Copyright 2026 CHIICH contributors.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import AuthenticationServices

/// Native browser presentation for the SDK's legacy SSO flow. No web-client session import.
@MainActor
final class SSOAuthenticationPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let service: SSOAuthenticationServiceProtocol
    private let anchor: UIWindow
    private let indicators: UserIndicatorControllerProtocol
    private let loadingID = "CHIICH-SSO-" + UUID().uuidString
    private var didStart = false
    private var requestID: UUID?
    private var isCancelled = false
    private var activeRequest: Request?

    private struct Request {
        let id: UUID
        let session: ASWebAuthenticationSession
        let continuation: CheckedContinuation<Result<URL, SSOError>, Never>
    }

    init(service: SSOAuthenticationServiceProtocol, anchor: UIWindow, indicators: UserIndicatorControllerProtocol) {
        self.service = service
        self.anchor = anchor
        self.indicators = indicators
        super.init()
    }

    func authenticate(provider: SSOIdentityProvider, expectedUserID: String? = nil) async -> Result<UserSessionProtocol, AuthenticationServiceError> {
        guard !didStart, !isCancelled,
              let scheme = Bundle.main.bundleIdentifier,
              let callback = SSOCallback(scheme: scheme) else { return .failure(.ssoError(.unavailable)) }
        didStart = true
        requestID = callback.id
        defer { stopLoading() }
        return await withTaskCancellationHandler {
            startLoading()
            let result = await service.beginSSOLogin(provider: provider, callback: callback)
            guard !isCancelled, !Task.isCancelled else {
                service.cancelSSOLogin(requestID: callback.id)
                return .failure(.ssoError(.cancelled))
            }
            let request: SSOLoginRequest
            switch result {
            case .success(let value): request = value
            case .failure(let error): return .failure(error)
            }
            stopLoading()
            let response = await present(request)
            guard !isCancelled, !Task.isCancelled else {
                service.cancelSSOLogin(requestID: callback.id)
                return .failure(.ssoError(.cancelled))
            }
            switch response {
            case .success(let url):
                startLoading()
                return await service.finishSSOLogin(requestID: request.id, callbackURL: url, expectedUserID: expectedUserID)
            case .failure(let error):
                service.cancelSSOLogin(requestID: callback.id)
                return .failure(.ssoError(error))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func present(_ request: SSOLoginRequest) async -> Result<URL, SSOError> {
        guard !isCancelled, let scheme = request.callback.url.scheme else { return .failure(.cancelled) }
        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(url: request.authorizationURL, callback: .customScheme(scheme)) { [weak self] url, error in
                Task { @MainActor in
                    let result: Result<URL, SSOError>
                    if let url {
                        result = request.callback.accepts(url) ? .success(url) : .failure(.invalidCallback)
                    } else {
                        result = .failure(error?.isOAuthUserCancellation == true ? .cancelled : .failed)
                    }
                    self?.complete(id: request.id, result: result)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            activeRequest = Request(id: request.id, session: session, continuation: continuation)
            if !session.start() { complete(id: request.id, result: .failure(.failed)) }
        }
    }

    private func complete(id: UUID, result: Result<URL, SSOError>) {
        guard let request = activeRequest, request.id == id else { return }
        activeRequest = nil
        request.continuation.resume(returning: result)
    }

    @discardableResult
    func cancel() -> Bool {
        if let requestID, !service.cancelSSOLogin(requestID: requestID) { return false }
        isCancelled = true
        if let request = activeRequest {
            activeRequest = nil
            request.session.cancel()
            // Programmatic ASWebAuthenticationSession cancellation does not call its callback.
            request.continuation.resume(returning: .failure(.cancelled))
        }
        stopLoading()
        return true
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { anchor }

    private func startLoading() {
        indicators.submitIndicator(UserIndicator(id: loadingID, type: .modal, title: L10n.commonLoading, persistent: true))
    }

    private func stopLoading() {
        indicators.retractIndicatorWithId(loadingID)
    }
}
