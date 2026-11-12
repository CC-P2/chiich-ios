// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

/// Stores only opaque IDs. Interrupted paid requests remain blocked after relaunch.
final class CHIICHReceiverAIClaimStore {
    private let fileURL: URL
    private var pending: Set<String>
    private let limit: Int
    var hasCapacity: Bool {
        pending.count < limit
    }
    
    init(accountID: String, directory: URL? = nil, limit: Int = 512) throws {
        self.limit = limit
        var root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory,
                                                            in: .userDomainMask,
                                                            appropriateFor: nil,
                                                            create: true).appendingPathComponent("CHIICHReceiverAI", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        fileURL = root.appendingPathComponent(CHIICHReceiverAIIdentity.hash([accountID]) + ".json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let data = try Data(contentsOf: fileURL)
            guard data.count <= 100_000 else { throw CHIICHReceiverAIError.storageUnavailable }
            pending = try Set(JSONDecoder().decode([String].self, from: data))
            guard pending.count <= limit, pending.allSatisfy(CHIICHReceiverAIRequest.validID) else {
                throw CHIICHReceiverAIError.storageUnavailable
            }
        } else {
            pending = []
        }
    }
    
    func contains(_ requestID: String) -> Bool {
        pending.contains(requestID)
    }
    
    func claim(_ requestID: String) throws {
        guard CHIICHReceiverAIRequest.validID(requestID) else { throw CHIICHReceiverAIError.invalidRequest }
        guard !pending.contains(requestID) else { throw CHIICHReceiverAIError.alreadyAttempted }
        guard hasCapacity else { throw CHIICHReceiverAIError.storageUnavailable }
        pending.insert(requestID)
        try persist()
    }
    
    func complete(_ requestID: String) throws {
        pending.remove(requestID)
        do {
            try persist()
        } catch {
            pending.insert(requestID)
            throw error
        }
    }
    
    private func persist() throws {
        let data = try JSONEncoder().encode(pending.sorted())
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
