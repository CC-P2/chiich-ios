// Copyright 2026 CHIICH contributors.
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation
@testable import ElementX
import Testing

@MainActor
struct ElementCallConfigurationTests {
    private let bundledURL = URL(fileURLWithPath: "/ElementCall/index.html")
    private let overrideURL = URL(string: "https://example.invalid/arbitrary")!

    @Test
    func releaseAndNightlyIgnoreSavedExternalOverride() {
        for buildType in [AppBuildType.release, .nightly] {
            #expect(ElementCallConfiguration.resolvedBaseURL(defaultURL: bundledURL,
                                                             overrideURL: overrideURL,
                                                             buildType: buildType) == bundledURL)
        }
    }

    @Test
    func debugCanUseExternalOverride() {
        #expect(ElementCallConfiguration.resolvedBaseURL(defaultURL: bundledURL,
                                                         overrideURL: overrideURL,
                                                         buildType: .debug) == overrideURL)
    }

    @Test
    func everyBuildUsesBundledPageWithoutOverride() {
        for buildType in [AppBuildType.debug, .nightly, .release] {
            #expect(ElementCallConfiguration.resolvedBaseURL(defaultURL: bundledURL,
                                                             overrideURL: nil,
                                                             buildType: buildType) == bundledURL)
        }
    }
}
