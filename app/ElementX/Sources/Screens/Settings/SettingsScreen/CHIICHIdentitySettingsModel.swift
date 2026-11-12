// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Observation
import SwiftUI

@Observable
final class CHIICHIdentitySettingsModel {
    private(set) var username: CHIICHPublicUsername?
    private(set) var hasLoaded = false
    private(set) var isBusy = false
    private(set) var isEditing = false
    private(set) var needsReload = false
    private(set) var error: CHIICHIdentityError?
    var draft = ""

    private let service: CHIICHIdentityService
    private let userIndicatorController: UserIndicatorControllerProtocol

    var shareURL: URL? {
        service.isSessionCurrent && !needsReload ? username?.link : nil
    }

    var canBeginEditing: Bool {
        hasLoaded && !isBusy && !needsReload && service.isSessionCurrent
    }

    var canSave: Bool {
        guard isEditing, !isBusy, !needsReload, service.isSessionCurrent,
              let candidate = try? CHIICHPublicUsername(chosen: draft) else { return false }
        return candidate != username
    }

    var isDraftValid: Bool { (try? CHIICHPublicUsername(chosen: draft)) != nil }

    init(service: CHIICHIdentityService, userIndicatorController: UserIndicatorControllerProtocol) {
        self.service = service
        self.userIndicatorController = userIndicatorController
    }

    func loadIfNeeded() async {
        guard !hasLoaded || needsReload else { return }
        await reload()
    }

    func reload() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let result = await service.current()
        guard !Task.isCancelled else { return }
        guard service.isSessionCurrent else { invalidateSession(); return }
        switch result {
        case .success(let confirmed):
            username = confirmed
            hasLoaded = true
            if !isEditing { draft = confirmed?.value ?? "" }
            needsReload = false
            error = nil
        case .failure(let failure):
            error = failure
        }
    }

    func beginEditing() {
        guard canBeginEditing else { return }
        draft = username?.value ?? ""
        isEditing = true
        error = nil
    }

    func cancelEditing() {
        guard !isBusy else { return }
        draft = username?.value ?? ""
        isEditing = false
        error = needsReload ? .uncertain : nil
    }

    func save() async {
        guard canSave, let candidate = try? CHIICHPublicUsername(chosen: draft) else { return }
        isBusy = true
        error = nil
        defer { isBusy = false }
        let result = await service.rename(to: candidate)
        guard service.isSessionCurrent else { invalidateSession(); return }
        guard !Task.isCancelled else {
            // Cancelling the client cannot undo a rename already accepted by the server.
            needsReload = true
            error = .uncertain
            return
        }
        switch result {
        case .success(let confirmed):
            username = confirmed
            draft = confirmed.value
            isEditing = false
            needsReload = false
        case .failure(let failure):
            error = failure
            switch failure {
            case .invalidUsername, .aliasLimit, .rateLimited:
                break
            default:
                // Refresh before another mutation or sharing a supposedly current name.
                needsReload = true
            }
        }
    }

    func copyInvitation() {
        guard let shareURL else {
            if !service.isSessionCurrent { invalidateSession() }
            return
        }
        UIPasteboard.general.url = shareURL
        userIndicatorController.submitIndicator(UserIndicator(id: "chiich.identity.copied",
                                                              type: .toast,
                                                              title: L10n.commonLinkCopiedToClipboard,
                                                              icon: \.check))
    }

    private func invalidateSession() {
        username = nil
        hasLoaded = false
        draft = ""
        isEditing = false
        needsReload = true
        error = .sessionChanged
    }

    static func preview(editing: Bool = false, loading: Bool = false, failure: CHIICHIdentityError? = nil,
                        hasChosenUsername: Bool = true) -> CHIICHIdentitySettingsModel {
        let service = CHIICHIdentityService(request: { _ in .failure(failure ?? .unavailable) }, isSessionCurrent: { true })
        let model = CHIICHIdentitySettingsModel(service: service, userIndicatorController: UserIndicatorControllerMock())
        model.username = loading || !hasChosenUsername ? nil : (try? CHIICHPublicUsername(chosen: "Ivan"))
        model.hasLoaded = !loading
        model.draft = model.username?.value ?? ""
        model.isEditing = editing
        model.isBusy = loading
        model.error = failure
        model.needsReload = failure != nil
        return model
    }
}
