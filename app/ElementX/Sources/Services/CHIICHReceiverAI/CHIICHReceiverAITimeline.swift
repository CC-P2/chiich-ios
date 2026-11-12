// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.

import Foundation

enum CHIICHReceiverAITimeline {
    static func invalidateIfNeeded(_ item: EventBasedTimelineItemProtocol, roomID: String, receiver: CHIICHReceiverAIService) -> Bool {
        guard let eventID = item.id.eventID else { return false }
        if item.isRedacted {
            receiver.redact(roomID: roomID, eventID: eventID)
            return true
        }
        if item.hasFailedDecryption {
            receiver.suspend(roomID: roomID, eventID: eventID)
            return true
        }
        return false
    }
    
    static func event(from item: EventBasedTimelineItemProtocol,
                      roomID: String,
                      ownUserID: String,
                      hideMedia: Bool,
                      editJSON: () -> String?) -> CHIICHReceiverAIEvent? {
        guard let eventID = item.id.eventID, !item.isOutgoing, item.sender.id != ownUserID,
              !item.isRedacted, !item.hasFailedDecryption else { return nil }
        let content: CHIICHReceiverAIEvent.Content
        switch item {
        case let text as TextRoomTimelineItem:
            content = .text(text.body)
        case let voice as VoiceMessageRoomTimelineItem:
            guard !hideMedia, let source = voice.content.source else { return nil }
            content = .audio(source, filename: voice.content.filename, byteCount: voice.content.fileSize)
        case let audio as AudioRoomTimelineItem:
            guard !hideMedia, let source = audio.content.source else { return nil }
            content = .audio(source, filename: audio.content.filename, byteCount: audio.content.fileSize)
        default: return nil
        }
        let timestamp = Int64(item.timestamp.timeIntervalSince1970 * 1000)
        let edit = item.properties.isEdited ? editMetadata(from: editJSON()) : nil
        let revision = item.properties.isEdited ? (edit?.id ?? eventID + ":edited") : eventID
        return .init(roomID: roomID, eventID: eventID, revision: revision, senderID: item.sender.id, content: content,
                     revisionTimestamp: edit?.timestamp ?? timestamp + (item.properties.isEdited ? 1 : 0))
    }
    
    private static func editMetadata(from json: String?) -> (id: String, timestamp: Int64)? {
        guard let data = json?.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identifier = object["event_id"] as? String,
              let timestamp = object["origin_server_ts"] as? NSNumber else { return nil }
        return (identifier, timestamp.int64Value)
    }
}
