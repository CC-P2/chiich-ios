// Copyright 2026 CHIICH.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

@testable import ElementX
import Foundation
import Testing

struct CHIICHAppURLFallbackTests {
    @Test(arguments: ["one.chiich.app://user/ivan?unexpected=1", "one.chiich.app://user/invalid/name",
                      "one.chiich.app://wrong/ivan", "one.chiich.app://sso/expired?loginToken=synthetic",
                      "ONE.CHIICH.APP://user/ivan?unexpected=1"])
    func rejectedOwnedURLCannotReopenTheSameApp(_ address: String) throws {
        let original = try #require(URL(string: address))
        #expect(AppURLFallback.systemBrowserURL(for: original, applicationScheme: "one.chiich.app") == nil)
    }

    @Test
    func ordinaryWebFallbackKeepsItsDestinationAndLoopPreventionFlag() throws {
        let original: URL = "https://chiich.one/ivan?source=web#part"
        let destination = try #require(AppURLFallback.systemBrowserURL(for: original, applicationScheme: "one.chiich.app"))
        let components = try #require(URLComponents(url: destination, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "chiich.one")
        #expect(components.path == "/ivan")
        #expect(components.fragment == "part")
        #expect(components.queryItems == [.init(name: "source", value: "web"), .init(name: "no_universal_links", value: "true")])
    }

    @Test
    func registeredOAuthAndInvitationRoutesStillResolveBeforeFallback() throws {
        let settings = AppSettings.volatile()
        let parser = AppRouteURLParser(appSettings: settings)
        let callback = settings.oAuthRedirectURL.appending(queryItems: [.init(name: "code", value: "synthetic")])
        #expect(parser.route(from: callback) == .oAuthCallback(url: callback))
        let alias = try CHIICHPublicUsername("ivan2026")
        #expect(parser.route(from: alias.appLink) == .chiichPublicUsername(alias))
    }
}
