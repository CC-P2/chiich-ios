//
// Copyright 2026 CHIICH contributors.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import Combine
@testable import ElementX
import Foundation
import Macros
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CHIICHNativeServicesTests {
    // Synthetic metadata only. No network requests or APNs credentials are used.
    private var services: [String: Any] {
        ["schema_version": 1,
         "mode": "services-enabled",
         "team_id": "RM8GR3A69Q",
         "bundle_id": "one.chiich.app",
         "pusher_app_id": "one.chiich.app.ios.prod",
         "apns_environment": "production",
         "gateway_base_url": "https://synthetic-push.onrender.com",
         "render_service_id": "srv-00000000000000000000",
         "gateway_ownership_verified": true,
         "universal_links": false]
    }

    @Test
    func missingMetadataKeepsTheTrialDefaults() {
        #expect(InfoPlistReader.chiichPushGatewayBaseURL(from: nil) == nil)
        let preferences = ServicePreferenceFixture<TrialServiceDefaults>(store: VolatileUserDefaults())
        #expect(!preferences.enableNotifications)
        #expect(preferences.hasRunNotificationPermissionsOnboarding)
    }

    @Test
    func unconfiguredApplicationUsesTheExistingNativeTrialPreferences() {
        let settings = AppSettings.volatile()
        #expect(settings.pushGatewayBaseURL.absoluteString == "https://notifications.invalid")
        #expect(settings.hasRunNotificationPermissionsOnboarding)
        #expect(!settings.userSettings(for: "@synthetic:chat.chiich.one").account.enableNotifications)
    }

    @Test
    func untouchedTrialPreferencesUseNativeDefaultsWhenServicesBecomeAvailable() throws {
        let store = VolatileUserDefaults()
        let trial = ServicePreferenceFixture<TrialServiceDefaults>(store: store)
        #expect(!trial.enableNotifications)
        #expect(trial.hasRunNotificationPermissionsOnboarding)
        let gateway = try #require(InfoPlistReader.chiichPushGatewayBaseURL(from: services))
        let enabled = ServicePreferenceFixture<EnabledServiceDefaults>(store: store)
        #expect(enabled.enableNotifications)
        #expect(!enabled.hasRunNotificationPermissionsOnboarding)
        #expect(gateway.absoluteString == "https://synthetic-push.onrender.com")
    }

    @Test
    func explicitOptOutAndCompletedOnboardingSurviveServiceActivation() throws {
        let store = VolatileUserDefaults()
        let trial = ServicePreferenceFixture<TrialServiceDefaults>(store: store)
        trial.enableNotifications = false
        trial.hasRunNotificationPermissionsOnboarding = true
        _ = try #require(InfoPlistReader.chiichPushGatewayBaseURL(from: services))
        let enabled = ServicePreferenceFixture<EnabledServiceDefaults>(store: store)
        #expect(!enabled.enableNotifications)
        #expect(enabled.hasRunNotificationPermissionsOnboarding)
    }

    @Test(arguments: ["https://notifications.invalid", "http://synthetic-push.onrender.com",
                      "https://synthetic-push.onrender.com/", "https://synthetic-push.onrender.com/_matrix/push/v1/notify",
                      "https://synthetic-push.onrender.com?x=1", "https://synthetic-push.onrender.com#fragment",
                      "https://user@synthetic-push.onrender.com", "https://synthetic-push.onrender.com:443",
                      "https://synthetic-push.onrender.com.evil.invalid", "https://SYNTHETIC-push.onrender.com",
                      "https://synthetic-push.onrender.com\n"])
    func malformedOrUnreviewedGatewayFailsClosed(origin: String) {
        var candidate = services
        candidate["gateway_base_url"] = origin
        #expect(InfoPlistReader.chiichPushGatewayBaseURL(from: candidate) == nil)
    }

    @Test
    func wrongIdentityOrIncompleteReviewFailsClosed() {
        let mutations: [(String, Any)] = [("schema_version", true), ("mode", "disabled-trial"),
                                         ("team_id", "OTHERTEAM00"), ("bundle_id", "io.element.elementx"),
                                         ("pusher_app_id", "one.chiich.app.ios.dev"), ("apns_environment", "development"),
                                         ("render_service_id", ""), ("gateway_ownership_verified", false),
                                         ("gateway_ownership_verified", 1), ("universal_links", "false"),
                                         ("unexpected_secret_field", "synthetic")]
        for (key, value) in mutations {
            var candidate = services
            candidate[key] = value
            #expect(InfoPlistReader.chiichPushGatewayBaseURL(from: candidate) == nil)
        }
        for key in services.keys {
            var candidate = services
            candidate.removeValue(forKey: key)
            #expect(InfoPlistReader.chiichPushGatewayBaseURL(from: candidate) == nil)
        }
    }
}

/// Use the real native macro and store to exercise an app update without changing
/// Bundle.main or persisting a synthetic gateway in any application configuration.
private protocol ServiceDefaults {
    static var gateway: URL? { get }
}

private enum TrialServiceDefaults: ServiceDefaults {
    static let gateway: URL? = nil
}

private enum EnabledServiceDefaults: ServiceDefaults {
    static let gateway = URL(string: "https://synthetic-push.onrender.com")
}

private final class ServicePreferenceFixture<Defaults: ServiceDefaults> {
    private let store: UserDefaultsProtocol

    @UserPreference(defaultValue: Defaults.gateway != nil)
    var enableNotifications: Bool

    @UserPreference(defaultValue: Defaults.gateway == nil)
    var hasRunNotificationPermissionsOnboarding: Bool

    init(store: UserDefaultsProtocol) {
        self.store = store
    }
}
