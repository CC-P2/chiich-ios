// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import Testing

struct CHIICHIdentityRequestTests {
    @Test(arguments: [("IVAN2026", "ivan2026"), ("ИВАН123", "иван123"), ("Ёжик", "ёжик"),
                      ("Ｅｖａ１２３", "eva123"), ("Е\u{0308}жик", "ёжик"), ("123", "123")])
    func normalisationMatchesTheExistingRegistry(_ input: String, _ expected: String) throws {
        let alias = try CHIICHPublicUsername(input)
        #expect(alias.value == expected)
        #expect(alias.link.host() == "chiich.one")
        #expect(alias.link.path(percentEncoded: false) == "/" + expected)
        #expect(alias.link.query() == nil)
    }

    @Test(arguments: ["Ivan", "Иван", "Ёжик", "user12345678", "123"])
    func chosenSpellingIsPreservedInTheShortLink(_ input: String) throws {
        let alias = try CHIICHPublicUsername(chosen: input)
        #expect(alias.value == input)
        #expect(alias.canonicalValue == (try CHIICHPublicUsername(input)).value)
        #expect(alias.link.path(percentEncoded: false) == "/" + input)
        #expect(alias.link.query() == nil)
        #expect(alias.displayLink == "chiich.one/" + input)
    }

    @Test(arguments: ["Ｅｖａ１２３", "Е\u{0308}жик", " Ivan", "Ivan ", "Ivan_Name", "ivаn", "admin", "ab"])
    func newChoicesAreNeverSilentlyCleanedOrNormalised(_ input: String) {
        #expect(throws: CHIICHIdentityError.self) { try CHIICHPublicUsername(chosen: input) }
    }

    @Test(arguments: ["ab", String(repeating: "a", count: 25), "ivan petrov", "ivan_petrov", "ivan-petrov", "\u{1F600}abc",
                      "ivаn", "Straße", "аbc", "admin", "LOGIN", "Иван/123", "ivan%2Fbob", "ivan\n", "@ivan"])
    func invalidNamesNeverReachTheServer(_ value: String) {
        #expect(throws: CHIICHIdentityError.self) { try CHIICHPublicUsername(value) }
    }

    @Test(arguments: ["https://matrix.chiich.one", "https://chiich-matrix.onrender.com/", "https://matrix.chiich.one:443"])
    func currentUsesOnlyTheExistingModule(_ origin: String) throws {
        let request = try CHIICHIdentityRequest.current.urlRequest(homeserver: origin)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/_synapse/client/chiich/username")
        #expect(request.url?.query() == "selection=explicit")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test(arguments: ["http://matrix.chiich.one", "https://evil.invalid", "https://matrix.chiich.one.evil.invalid",
                      "https://matrix.chiich.one/path", "https://matrix.chiich.one?token=synthetic", "https://matrix.chiich.one#part",
                      "https://user@matrix.chiich.one", "https://matrix.chiich.one:8448"])
    func untrustedOriginsCannotReceiveSessionCredentials(_ origin: String) {
        #expect(throws: CHIICHIdentityError.self) { try CHIICHIdentityRequest.current.urlRequest(homeserver: origin) }
    }

    @Test
    func renameHasOnlyThePublicUsernameAndResolveHasNoBody() throws {
        let alias = try CHIICHPublicUsername(chosen: "ИВАН2026")
        let rename = try CHIICHIdentityRequest.rename(alias).urlRequest(homeserver: "https://matrix.chiich.one")
        let data = try #require(rename.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["username": "ИВАН2026"])
        #expect(rename.url?.query() == "selection=explicit")
        #expect(rename.httpMethod == "PUT")
        #expect(rename.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let resolve = try CHIICHIdentityRequest.resolve(alias).urlRequest(homeserver: "https://matrix.chiich.one")
        #expect(resolve.httpMethod == "GET")
        #expect(resolve.url?.path(percentEncoded: false) == "/_synapse/client/chiich/username/иван2026")
        #expect(resolve.httpBody == nil)
        #expect(resolve.url?.query() == nil)
    }

    @Test
    func explicitResponseSeparatesNoChoiceFromMissingOrMismatchedFields() throws {
        func decode(_ json: String) throws -> CHIICHPublicUsername? {
            try JSONDecoder().decode(CHIICHIdentityResponse.self, from: Data(json.utf8)).validated()
        }
        #expect(try decode(#"{"username":null,"display_username":null}"#) == nil)
        #expect(try decode(#"{"username":"ivan","display_username":"Ivan"}"#)?.value == "Ivan")
        for json in [#"{}"#, #"{"username":"user12345678"}"#, #"{"username":null}"#,
                     #"{"username":"ivan","display_username":null}"#, #"{"username":null,"display_username":"Ivan"}"#,
                     #"{"username":"other","display_username":"Ivan"}"#, #"{"username":"Ivan","display_username":"Ivan"}"#,
                     #"{"username":"eva123","display_username":"Ｅｖａ１２３"}"#] {
            #expect(throws: (any Error).self) { try decode(json) }
        }
    }

    @Test
    func oldAliasCanResolveToItsOwnersNewName() throws {
        let recipient = try CHIICHIdentityRecipient(username: "newname", userID: "@existing=40email:chat.chiich.one").validated()
        #expect(recipient.username == "newname")
        #expect(recipient.userID == "@existing=40email:chat.chiich.one")
    }

    @Test(arguments: ["@someone:evil.invalid", "@someone:chat.chiich.one.evil.invalid", "@someone\n:chat.chiich.one", "@a:chat.chiich.one\n"])
    func resolvedRecipientMustBelongToTheExistingServer(_ userID: String) {
        #expect(throws: CHIICHIdentityError.self) { try CHIICHIdentityRecipient(username: "ivan", userID: userID).validated() }
    }

    @Test(arguments: [true, false])
    func onlyTheExactMatrixAuthenticationErrorTriggersNativeLogout(_ softLogout: Bool) throws {
        let data = try JSONSerialization.data(withJSONObject: ["errcode": "M_UNKNOWN_TOKEN", "soft_logout": softLogout])
        #expect(error(CHIICHIdentityHTTP.classify(data: data, statusCode: 401)) == .matrixUnknownToken(softLogout: softLogout))
        #expect(error(CHIICHIdentityHTTP.classify(data: data, statusCode: 403)) == .unavailable)
    }

    @Test
    func serverErrorsRetainActionableMeaningAndMalformedRepliesFailClosed() {
        let cases: [(Int, String, CHIICHIdentityError)] = [
            (400, "M_INVALID_PARAM", .invalidUsername), (400, "M_USERNAME_LIMIT_EXCEEDED", .aliasLimit),
            (409, "M_CONFLICT", .conflict), (429, "M_LIMIT_EXCEEDED", .rateLimited), (404, "M_NOT_FOUND", .notFound)
        ]
        for (status, code, expected) in cases {
            let data = Data("{\"errcode\":\"\(code)\"}".utf8)
            #expect(error(CHIICHIdentityHTTP.classify(data: data, statusCode: status)) == expected)
        }
        #expect(error(CHIICHIdentityHTTP.classify(data: Data("not json".utf8), statusCode: 401)) == .unavailable)
        #expect(error(CHIICHIdentityHTTP.classify(data: Data(count: 16_385), statusCode: 200)) == .invalidResponse)
        #expect(error(CHIICHIdentityHTTP.classify(data: Data(), statusCode: 302)) == .unavailable)
    }

    private func error(_ result: Result<Data, CHIICHIdentityError>) -> CHIICHIdentityError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}
