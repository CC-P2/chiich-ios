//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//
// Synthetic content for CHIICH UI-test captures only.
// These are not real accounts, messages or live-service acceptance results.
//

import Foundation
import MatrixRustSDKMocks

enum CHIICHStoreScreenshotFixture {
    static let userID = "@demo:example.invalid"
    static let displayName = "Демо ЧИИЧ"
    static let status = UserStatus()
    static let searchQuery = "Планы на выходные"

    static var rooms: [RoomSummary] {
        let referenceDate = Date()
        return [
            room(id: "weekend",
                 name: searchQuery,
                 message: "Давайте встретимся в парке в субботу.",
                 date: referenceDate.addingTimeInterval(-120)),
            room(id: "anna",
                 name: "Анна",
                 message: "Спасибо! Напишу, когда буду рядом.",
                 date: referenceDate.addingTimeInterval(-600),
                 personID: "@demo_anna:example.invalid",
                 unreadCount: 2),
            room(id: "family",
                 name: "Семья",
                 message: "Фотографии получились отличные!",
                 date: referenceDate.addingTimeInterval(-1800)),
            room(id: "project",
                 name: "Новый проект",
                 message: "Обсудим идеи завтра утром.",
                 date: referenceDate.addingTimeInterval(-3600),
                 unreadCount: 1),
            room(id: "maksim",
                 name: "Максим",
                 message: "Договорились, до встречи!",
                 date: referenceDate.addingTimeInterval(-7200),
                 personID: "@demo_maksim:example.invalid")
        ]
    }

    @MainActor
    static func recentlyVisitedRooms(from summaries: [RoomSummary]) -> [JoinedRoomProxyProtocol] {
        summaries.map { summary in
            JoinedRoomProxyMock(.init(id: summary.id,
                                     name: summary.name,
                                     isDirect: summary.isDirect,
                                     isSpace: false,
                                     isEncrypted: false,
                                     hasOngoingCall: false,
                                     members: [],
                                     ownUserID: userID))
        }
    }

    private static func room(id: String,
                             name: String,
                             message: String,
                             date: Date,
                             personID: String? = nil,
                             unreadCount: UInt = 0) -> RoomSummary {
        let heroes = personID.map { [UserProfile(userID: $0, displayName: name)] } ?? []
        return RoomSummary(room: RoomSDKMock(.init()),
                           id: "!demo_\(id):example.invalid",
                           joinRequestType: nil,
                           isJoined: true,
                           name: name,
                           isDirect: personID != nil,
                           isSpace: false,
                           avatarURL: nil,
                           heroes: heroes,
                           activeMembersCount: personID == nil ? 4 : 2,
                           lastMessage: AttributedString(message),
                           lastMessageDate: date,
                           lastMessageState: nil,
                           unreadMessagesCount: unreadCount,
                           unreadMentionsCount: 0,
                           unreadNotificationsCount: unreadCount,
                           notificationMode: .allMessages,
                           canonicalAlias: nil,
                           alternativeAliases: [],
                           hasOngoingCall: false,
                           activeCallIntent: nil,
                           isMarkedUnread: false,
                           isFavourite: false,
                           isTombstoned: false)
    }
}
