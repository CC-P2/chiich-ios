//
// Copyright 2026 CHIICH.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

@testable import ElementX
import SwiftUI
import Testing

struct CHIICHMessageDisclosureTests {
    @Test
    func shortAndExactlyHalfScreenMessagesStayVisible() {
        for height in [CGFloat(20), CGFloat(260)] {
            let metrics = CHIICHMessageDisclosureMetrics(contentHeight: height, viewportHeight: 600, reservedHeight: 40, controlHeight: 44)
            #expect(!metrics.needsDisclosure)
        }
    }
    
    @Test
    func longMessagesReserveSpaceForMetadataAndDisclosure() {
        let metrics = CHIICHMessageDisclosureMetrics(contentHeight: 700, viewportHeight: 600, reservedHeight: 40, controlHeight: 44)
        #expect(metrics.needsDisclosure)
        #expect(metrics.collapsedContentHeight + 40 + 44 == 300)
    }
    
    @Test
    func dynamicTypeAndSmallViewportsHaveNonnegativeBudgets() {
        let largerControl = CHIICHMessageDisclosureMetrics(contentHeight: 700, viewportHeight: 600, reservedHeight: 60, controlHeight: 100)
        #expect(largerControl.collapsedContentHeight == 140)
        let keyboardVisible = CHIICHMessageDisclosureMetrics(contentHeight: 700, viewportHeight: 120, reservedHeight: 60, controlHeight: 44)
        #expect(keyboardVisible.collapsedContentHeight == 0)
        let notLaidOut = CHIICHMessageDisclosureMetrics(contentHeight: 700, viewportHeight: 0, reservedHeight: 60, controlHeight: 44)
        #expect(!notLaidOut.needsDisclosure)
    }
    
    @Test
    func unreadCountsKeepTheApprovedTenThenInfinityBoundary() {
        #expect(CHIICHUnreadCount.label(for: 0).isEmpty)
        #expect(CHIICHUnreadCount.label(for: 1) == "I")
        #expect(CHIICHUnreadCount.label(for: 10) == "X")
        #expect(CHIICHUnreadCount.label(for: 11) == "∞")
        #expect(CHIICHUnreadCount.label(for: .max) == "∞")
    }
}
