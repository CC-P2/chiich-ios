// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Combine
@testable import ElementX
import Foundation
import Testing

struct CHIICHIdentitySettingsTests {
    @Test
    func loadsCurrentNameWithoutRenamingAndCancellationKeepsIt() async throws {
        let fixture = Fixture()
        await fixture.model.loadIfNeeded()
        await fixture.model.loadIfNeeded()
        #expect(fixture.requests == [.current])
        #expect(fixture.model.username?.value == "oldname")
        fixture.model.beginEditing()
        fixture.model.draft = "newname"
        fixture.model.cancelEditing()
        #expect(fixture.model.draft == "oldname")
        #expect(fixture.model.username?.value == "oldname")
        #expect(fixture.requests == [.current])
    }

    @Test
    func successfulSaveChangesOnlyTheAliasAndShareLink() async throws {
        let fixture = Fixture()
        await fixture.model.loadIfNeeded()
        fixture.model.beginEditing()
        fixture.model.draft = "ИВАН2026"
        await fixture.model.save()
        #expect(fixture.model.username?.value == "ИВАН2026")
        #expect(fixture.model.shareURL?.path(percentEncoded: false) == "/ИВАН2026")
        #expect(!fixture.model.isEditing)
        #expect(fixture.requests == [.current, .rename(try CHIICHPublicUsername(chosen: "ИВАН2026"))])
    }

    @Test
    func firstChoiceIsEditableWithoutAnAutomaticNameOrShareLink() async throws {
        let fixture = Fixture()
        fixture.currentName = nil
        #expect(!fixture.model.canBeginEditing)
        await fixture.model.loadIfNeeded()
        await fixture.model.loadIfNeeded()
        #expect(fixture.requests == [.current])
        #expect(fixture.model.username == nil)
        #expect(fixture.model.shareURL == nil)
        #expect(fixture.model.canBeginEditing)
        fixture.model.beginEditing()
        #expect(fixture.model.draft.isEmpty)
        #expect(!fixture.model.canSave)
        fixture.model.draft = "Ivan"
        #expect(fixture.model.canSave)
        await fixture.model.save()
        #expect(fixture.model.username?.value == "Ivan")
        #expect(fixture.model.shareURL?.absoluteString == "https://chiich.one/Ivan")
        #expect(fixture.requests == [.current, .rename(try CHIICHPublicUsername(chosen: "Ivan"))])
    }

    @Test
    func firstChoiceConflictKeepsTheTypedNameWithoutAddingASuffix() async {
        let fixture = Fixture()
        fixture.currentName = nil
        await fixture.model.loadIfNeeded()
        fixture.model.beginEditing()
        fixture.model.draft = "Ivan"
        fixture.renameError = .conflict
        await fixture.model.save()
        #expect(fixture.model.username == nil)
        #expect(fixture.model.shareURL == nil)
        #expect(fixture.model.draft == "Ivan")
        #expect(fixture.model.error == .conflict)
        await fixture.model.reload()
        #expect(fixture.model.draft == "Ivan")
        fixture.model.draft = "Another"
        fixture.renameError = nil
        await fixture.model.save()
        #expect(fixture.model.username?.value == "Another")
    }

    @Test
    func caseOnlyEditCanBeSavedAndExactRetryIsDisabled() async {
        let fixture = Fixture()
        fixture.currentName = "Ivan"
        await fixture.model.loadIfNeeded()
        fixture.model.beginEditing()
        #expect(!fixture.model.canSave)
        fixture.model.draft = "IVAN"
        #expect(fixture.model.canSave)
        await fixture.model.save()
        #expect(fixture.model.username?.value == "IVAN")
        fixture.model.beginEditing()
        #expect(!fixture.model.canSave)
    }

    @Test(arguments: ["ab", "admin", "aБв", "ivan_name", " Ivan", "Ivan ", "Ｅｖａ１２３", "Е\u{0308}жик"])
    func invalidEditsCannotSendARename(_ name: String) async {
        let fixture = Fixture()
        await fixture.model.loadIfNeeded()
        fixture.model.beginEditing()
        fixture.model.draft = name
        #expect(!fixture.model.canSave)
        await fixture.model.save()
        #expect(fixture.requests == [.current])
    }

    @Test
    func uncertainRenameRequiresReadBackBeforeRetryOrSharing() async {
        let fixture = Fixture()
        await fixture.model.loadIfNeeded()
        fixture.model.beginEditing()
        fixture.model.draft = "newname"
        fixture.renameError = .uncertain
        await fixture.model.save()
        #expect(fixture.model.needsReload)
        #expect(!fixture.model.canSave)
        #expect(fixture.model.shareURL == nil)
        await fixture.model.save()
        #expect(fixture.requests.count == 2)
        // The first request may have committed despite losing its response.
        fixture.currentName = "newname"
        await fixture.model.reload()
        #expect(fixture.model.username?.value == "newname")
        #expect(fixture.model.shareURL?.path == "/newname")
        #expect(!fixture.model.needsReload)
        #expect(!fixture.model.canSave)
        #expect(fixture.requests.count == 3)
    }

    @Test
    func conflictingRenamePreservesTheDraftAndRefreshesTheServerValue() async {
        let fixture = Fixture()
        await fixture.model.loadIfNeeded()
        fixture.model.beginEditing()
        fixture.model.draft = "wantedname"
        fixture.renameError = .conflict
        await fixture.model.save()
        #expect(fixture.model.error == .conflict)
        #expect(fixture.model.draft == "wantedname")
        fixture.currentName = "otherdevice"
        await fixture.model.reload()
        #expect(fixture.model.username?.value == "otherdevice")
        #expect(fixture.model.draft == "wantedname")
        #expect(fixture.model.canSave)
    }

    @Test
    func duplicateSaveAndLateResponseCannotCrossLogout() async throws {
        let fixture = Fixture()
        await fixture.model.loadIfNeeded()
        fixture.model.beginEditing()
        fixture.model.draft = "newname"
        fixture.holdRename = true
        let started = deferFulfillment(fixture.pendingPublisher) { $0 }
        let saving = Task { await fixture.model.save() }
        try await started.fulfill()
        await fixture.model.save()
        #expect(fixture.requests.count == 2)
        fixture.sessionCurrent = false
        fixture.resumeRename(.success(Data(#"{"username":"newname","display_username":"newname"}"#.utf8)))
        await saving.value
        #expect(fixture.model.username == nil)
        #expect(fixture.model.shareURL == nil)
        #expect(fixture.model.error == .sessionChanged)
    }

    @Test
    func cancelledSaveCannotClaimSuccessOrAutomaticallyRepeatTheMutation() async throws {
        let fixture = Fixture()
        await fixture.model.loadIfNeeded()
        fixture.model.beginEditing()
        fixture.model.draft = "newname"
        fixture.holdRename = true
        let started = deferFulfillment(fixture.pendingPublisher) { $0 }
        let saving = Task { await fixture.model.save() }
        try await started.fulfill()
        saving.cancel()
        fixture.resumeRename(.success(Data(#"{"username":"newname","display_username":"newname"}"#.utf8)))
        await saving.value
        #expect(fixture.model.username?.value == "oldname")
        #expect(fixture.model.needsReload)
        #expect(fixture.model.error == .uncertain)
        #expect(fixture.requests.count == 2)
    }

    @Test
    func nativeServicePinsAccountDeviceAndHomeserver() async throws {
        let client = ClientProxyMock(.init(homeserver: "https://matrix.chiich.one", userID: "@alice:chat.chiich.one", deviceID: "ONE"))
        client.chiichReceiverAIIsSessionActive = true
        client.chiichIdentityRequestAccountIDReturnValue = .success(Data(#"{"username":"alice","display_username":"alice"}"#.utf8))
        let service = try #require(CHIICHIdentityService(clientProxy: client))
        _ = await service.current()
        #expect(client.chiichIdentityRequestAccountIDCallsCount == 1)
        client.deviceID = "TWO"
        #expect(!service.isSessionCurrent)
        #expect(await service.current() == .failure(.sessionChanged))
        #expect(client.chiichIdentityRequestAccountIDCallsCount == 1)
    }

    @Test(arguments: [#"{"username":"@technical:chat.chiich.one"}"#, #"{"username":"user12345678"}"#,
                      #"{"username":"ivan","display_username":"Other"}"#])
    func invalidSuccessfulReplyIsNotDisplayedOrShared(_ response: String) async throws {
        let service = CHIICHIdentityService(request: { _ in .success(Data(response.utf8)) },
                                            isSessionCurrent: { true })
        let model = CHIICHIdentitySettingsModel(service: service, userIndicatorController: UserIndicatorControllerMock())
        await model.reload()
        #expect(model.username == nil)
        #expect(model.shareURL == nil)
        #expect(!model.canBeginEditing)
        #expect(model.error == .invalidResponse)
    }

    @Test
    func successfulMutationMustConfirmTheExactSpelling() async throws {
        let requested = try CHIICHPublicUsername(chosen: "Ivan")
        for response in [#"{"username":null,"display_username":null}"#,
                         #"{"username":"ivan","display_username":"ivan"}"#,
                         #"{"username":"other","display_username":"Other"}"#] {
            let service = CHIICHIdentityService(request: { _ in .success(Data(response.utf8)) }, isSessionCurrent: { true })
            #expect(await service.rename(to: requested) == .failure(.invalidResponse))
        }
    }

    private final class Fixture {
        var currentName: String? = "oldname"
        var renameError: CHIICHIdentityError?
        var sessionCurrent = true
        var requests: [CHIICHIdentityRequest] = []
        var holdRename = false
        let pendingPublisher = CurrentValueSubject<Bool, Never>(false)
        private var pending: CheckedContinuation<Result<Data, CHIICHIdentityError>, Never>?
        lazy var model = CHIICHIdentitySettingsModel(service: CHIICHIdentityService(request: { [weak self] request in
            guard let self else { return .failure(.sessionChanged) }
            return await send(request)
        }, isSessionCurrent: { [weak self] in self?.sessionCurrent == true }),
                                                    userIndicatorController: UserIndicatorControllerMock())

        func resumeRename(_ result: Result<Data, CHIICHIdentityError>) {
            pending?.resume(returning: result)
            pending = nil
        }

        private func send(_ request: CHIICHIdentityRequest) async -> Result<Data, CHIICHIdentityError> {
            requests.append(request)
            switch request {
            case .current:
                return .success(currentResponse())
            case .rename(let name):
                if holdRename {
                    return await withCheckedContinuation { continuation in
                        pending = continuation
                        pendingPublisher.send(true)
                    }
                }
                if let renameError { return .failure(renameError) }
                currentName = name.value
                return .success(currentResponse())
            case .resolve:
                return .failure(.notFound)
            }
        }

        private func currentResponse() -> Data {
            guard let currentName else { return Data(#"{"username":null,"display_username":null}"#.utf8) }
            return Data("{\"username\":\"\(currentName.lowercased())\",\"display_username\":\"\(currentName)\"}".utf8)
        }
    }
}
