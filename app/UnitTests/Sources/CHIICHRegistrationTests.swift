// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation
import Testing
@testable import ElementX

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CHIICHRegistrationTests {
    private let id = "@reviewer:chat.chiich.one"
    private let token = "m.login.registration_token"
    private let dummy = "m.login.dummy"

    private func challenge(_ stages: [String], completed: [String] = [], session: String = "example") -> Result<CHIICHRegistration.Reply, CHIICHPasswordError> {
        let body: [String: Any] = ["session": session, "flows": [["stages": stages]], "completed": completed]
        return CHIICHRegistration.classify(try! JSONSerialization.data(withJSONObject: body), 401)
    }

    @Test func completesTheOfferedStagesAndUsesTheReturnedMatrixID() async throws {
        var requests = [URLRequest]()
        let result = await CHIICHRegistration.create(username: "reviewer", password: "example-password", invitation: "example-invite") { request in
            requests.append(request)
            switch requests.count {
            case 1: return challenge([token, dummy])
            case 2: return challenge([token, dummy], completed: [token])
            default: return CHIICHRegistration.classify(Data(#"{"user_id":"@reviewer:chat.chiich.one"}"#.utf8), 200)
            }
        }
        guard case .created(let userID) = result else { Issue.record("Registration did not complete"); return }
        #expect(userID == id)
        try #require(requests.count == 3)
        let bodies = try requests.map { request in
            #expect(request.url?.absoluteString == "https://matrix.chiich.one/_matrix/client/v3/register")
            #expect(request.httpMethod == "POST")
            let data = try #require(request.httpBody)
            let object = try JSONSerialization.jsonObject(with: data)
            let body = try #require(object as? [String: Any])
            #expect(body["inhibit_login"] as? Bool == true)
            #expect(body["username"] as? String == "reviewer")
            return body["auth"] as? [String: String]
        }
        #expect(bodies[0] == nil)
        #expect(bodies[1] == ["type": token, "session": "example", "token": "example-invite"])
        #expect(bodies[2] == ["type": dummy, "session": "example"])
    }

    @Test func missingInviteAndUnsupportedStagesNeverSubmitAuthentication() async {
        for (stage, expected) in [(token, "invite_needed"), ("m.login.recaptcha", "unsupported")] {
            var count = 0
            let result = await CHIICHRegistration.create(username: "reviewer", password: "example", invitation: "") { _ in
                count += 1
                return challenge([stage])
            }
            guard case .rejected(let reason) = result else { Issue.record("Unexpected result"); return }
            #expect(reason == expected)
            #expect(count == 1)
        }
    }

    @Test func stopsOnARepeatedOrChangedChallenge() async {
        for changeSession in [false, true] {
            var count = 0
            let result = await CHIICHRegistration.create(username: "reviewer", password: "example", invitation: "invite") { _ in
                count += 1
                return challenge([token], session: changeSession && count > 1 ? "replacement" : "original")
            }
            guard case .rejected = result else { Issue.record("Unexpected result"); return }
            #expect(count == 2)
        }
    }

    @Test func ambiguousResultsNeverRetryOrSignIn() async {
        let replies: [Result<CHIICHRegistration.Reply, CHIICHPasswordError>] = [.failure(.outcomeUnknown), .success(.created("@another:chat.chiich.one"))]
        for reply in replies {
            var count = 0
            let result = await CHIICHRegistration.create(username: "reviewer", password: "example", invitation: "") { _ in
                count += 1
                return reply
            }
            guard case .rejected("uncertain") = result else { Issue.record("Unexpected result"); return }
            #expect(count == 1)
        }
    }
}
