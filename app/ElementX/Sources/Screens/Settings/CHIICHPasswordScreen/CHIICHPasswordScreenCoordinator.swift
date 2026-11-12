// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Combine
import SwiftUI

final class CHIICHPasswordScreenCoordinator: CoordinatorProtocol {
    private let viewModel: CHIICHPasswordScreenViewModel

    var dismissalPublisher: AnyPublisher<Void, Never> { viewModel.dismissalPublisher }

    init(clientProxy: ClientProxyProtocol) {
        viewModel = CHIICHPasswordScreenViewModel(service: clientProxy.makeCHIICHPasswordService())
    }

    func start() {
        viewModel.start()
    }

    func stop() {
        // NavigationModule.tearDown calls stop for Back, swipe-back, and logout navigation teardown.
        viewModel.stop()
    }

    func toPresentable() -> AnyView {
        AnyView(CHIICHPasswordScreen(context: viewModel.context))
    }
}
