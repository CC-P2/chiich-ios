// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Combine
import SwiftUI

final class CHIICHDeletionScreenCoordinator: CoordinatorProtocol {
    private let viewModel: CHIICHDeletionScreenViewModel

    var dismissalPublisher: AnyPublisher<Void, Never> { viewModel.dismissalPublisher }

    init(clientProxy: ClientProxyProtocol) {
        viewModel = CHIICHDeletionScreenViewModel(service: clientProxy.makeCHIICHDeletionService())
    }

    func start() {
        viewModel.start()
    }

    func stop() {
        // NavigationModule.tearDown calls stop for Back, swipe-back, and logout navigation teardown.
        viewModel.stop()
    }

    func toPresentable() -> AnyView {
        AnyView(CHIICHDeletionScreen(context: viewModel.context))
    }
}
