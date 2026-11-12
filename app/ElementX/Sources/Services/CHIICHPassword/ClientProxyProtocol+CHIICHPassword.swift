// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

extension ClientProxyProtocol {
    // Mocks and unrelated clients do not acquire password-changing authority by default.
    var supportsCHIICHPassword: Bool { false }
    func makeCHIICHPasswordService() -> CHIICHPasswordService? { nil }
}
