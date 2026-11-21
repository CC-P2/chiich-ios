//
// Copyright 2026 CHIICH.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

import XCTest

/// Exercises the real session/tab coordinators. A standalone HomeScreen preview cannot catch
/// a second search button supplied by the enclosing TabView or a broken return from Spaces.
@MainActor
final class ChiichHomeControlsTests: XCTestCase {
    private enum Control {
        static let search = "chiich.home.search"
        static let closeSearch = "chiich.search.close"
        static let profile = "chiich.settings.profile"
        static let chats = "chiich.settings.section.chats"
        static let spaces = "chiich.settings.section.spaces"
        static let settingsSearch = "chiich.settings.search"
        static let spaceFilter = "chiich.settings.spaceFilter"
        static let clearSpaceFilter = "chiich.settings.clearSpaceFilter"
        static let clearFilters = "chiich.settings.clearFilters"
        static let filterNames = ["unreads", "mentions", "favourites", "people", "rooms", "invites", "lowPriority"]
        
        static func filter(_ name: String) -> String {
            "chiich.settings.filter.\(name)"
        }
    }
    
    private let groupRoom = "Foundation 🔭🪐🌌"
    private let directRoom = "Foundation and Earth"
    private let firstSpace = "The Foundation"
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }
    
    func testSingleNativeSearchEntryAndCancellation() async throws {
        let app = Application.launch(.chiichHomeControls)
        assertChatsAreVisible(app)
        assertSingleHomeSearch(app)
        try await attachRootScreenshot(app, name: "CHIICH-root-chats-light")
        
        app.buttons[Control.search].tap()
        assertNativeSearch(app, query: "Foundation and Empire", expectedRoom: "Foundation and Empire")
        XCTAssertFalse(app.buttons[A11yIdentifiers.searchScreen.roomName(groupRoom)].exists)
        try await attachRootScreenshot(app, name: "CHIICH-root-search-light")
        
        closeNativeSearch(app)
        assertChatsAreVisible(app)
        assertSingleHomeSearch(app)
        XCTAssertTrue(app.buttons[A11yIdentifiers.homeScreen.roomName(groupRoom)].exists)
    }
    
    func testSettingsFiltersAndSectionsShareHomeState() async throws {
        let app = Application.launch(.chiichHomeControls)
        assertChatsAreVisible(app)
        openSettings(app)
        try await attachRootScreenshot(app, name: "CHIICH-root-settings-light")
        assertSettingsControls(app)
        
        let people = app.switches[Control.filter("people")].firstMatch
        // Compound exposes the row as a switch; the actual toggle is its nested switch.
        let peopleToggle = people.switches.firstMatch
        reveal(peopleToggle, in: app, scrollingUp: false)
        XCTAssertTrue(peopleToggle.exists)
        XCTAssertTrue(peopleToggle.isHittable)
        peopleToggle.tap()
        XCTAssertEqual(people.value as? String, "1")
        closeSettings(app)
        assertPeopleFilterApplied(app)
        
        // Reopening Settings must observe the same live state that filtered the Home list.
        openSettings(app)
        XCTAssertEqual(app.switches[Control.filter("people")].firstMatch.value as? String, "1")
        selectSection(Control.spaces, in: app)
        assertSpacesAreVisible(app)
        assertNoTabControls(app)
        try await attachRootScreenshot(app, name: "CHIICH-root-spaces-light")
        
        // Settings remains reachable from Spaces, and cancelling its search returns to Spaces.
        openSettings(app)
        let selectedSpaces = app.switches[Control.spaces].firstMatch
        reveal(selectedSpaces, in: app)
        XCTAssertEqual(selectedSpaces.value as? String, "1", "Spaces should remain the selected native section.")
        XCTAssertEqual(app.switches[Control.chats].firstMatch.value as? String, "0")
        let search = app.buttons[Control.settingsSearch]
        reveal(search, in: app)
        search.tap()
        assertNativeSearch(app, query: "Second Foundation", expectedRoom: "Second Foundation")
        closeNativeSearch(app)
        assertSpacesAreVisible(app)
        
        openSettings(app)
        selectSection(Control.chats, in: app)
        assertPeopleFilterApplied(app)
        
        // The native clear action restores the complete list rather than resetting the session.
        openSettings(app)
        let clear = app.buttons[Control.clearFilters]
        reveal(clear, in: app)
        clear.tap()
        XCTAssertEqual(app.switches[Control.filter("people")].firstMatch.value as? String, "0")
        closeSettings(app)
        XCTAssertTrue(app.buttons[A11yIdentifiers.homeScreen.roomName(groupRoom)].waitForExistence(timeout: 5))
        assertSingleHomeSearch(app)
    }
    
    func testInlineSearchFallbackHasOneEntryAndCanCancel() {
        let app = Application.launch(.chiichHomeControlsInlineSearch)
        let firstRoom = app.buttons[A11yIdentifiers.homeScreen.roomName(groupRoom)]
        XCTAssertTrue(firstRoom.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons[Control.search].exists)
        assertNoTabControls(app)
        
        let field = app.searchFields.firstMatch
        let roomList = app.scrollViews.containing(.button, identifier: A11yIdentifiers.homeScreen.roomName(groupRoom)).firstMatch
        for _ in 0..<2 where !field.isHittable {
            roomList.swipeDown()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(field.isHittable)
        XCTAssertEqual(app.searchFields.count, 1)
        field.clearAndTypeText("Foundation and Empire", app: app)
        XCTAssertTrue(app.buttons[A11yIdentifiers.homeScreen.roomName("Foundation and Empire")].waitForExistence(timeout: 5))
        XCTAssertTrue(firstRoom.waitForNonExistence(timeout: 5))
        
        cancelInlineSearch(field, roomList: roomList, app: app)
        XCTAssertTrue(firstRoom.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Resetting native search should dismiss the keyboard.")
        XCTAssertFalse(app.buttons[Control.search].exists)
        XCTAssertEqual(app.searchFields.count, 1)
    }
    
    func testGraphiteRootComposition() async throws {
        let app = Application.launch(.chiichHomeControlsGraphite)
        assertChatsAreVisible(app)
        assertSingleHomeSearch(app)
        try await attachRootScreenshot(app, name: "CHIICH-root-chats-graphite")
        
        openSettings(app)
        try await attachRootScreenshot(app, name: "CHIICH-root-settings-graphite")
        selectSection(Control.spaces, in: app)
        assertSpacesAreVisible(app)
        assertNoTabControls(app)
        try await attachRootScreenshot(app, name: "CHIICH-root-spaces-graphite")
        
        openSettings(app)
        let search = app.buttons[Control.settingsSearch]
        reveal(search, in: app)
        search.tap()
        assertNativeSearch(app, query: "Foundation and Empire", expectedRoom: "Foundation and Empire")
        try await attachRootScreenshot(app, name: "CHIICH-root-search-graphite")
        closeNativeSearch(app)
        assertSpacesAreVisible(app)
        
        openSettings(app)
        selectSection(Control.chats, in: app)
        assertChatsAreVisible(app)
        assertSpaceFilterCanBeSelectedAndCleared(app)
    }
    
    // Existing regression methods never enable curated capture data.
    func testStoreLightScreenshots() async throws {
        try await captureStoreScreenshots(.chiichHomeControls, appearance: "light")
    }

    func testStoreGraphiteScreenshots() async throws {
        try await captureStoreScreenshots(.chiichHomeControlsGraphite, appearance: "graphite")
    }

    private func captureStoreScreenshots(_ identifier: UITestsScreenIdentifier, appearance: String) async throws {
        let app = Application.launch(identifier, storeCapture: true)
        assertChatsAreVisible(app)
        assertSingleHomeSearch(app)
        let demoRoom = "Планы на выходные"
        XCTAssertTrue(app.buttons[A11yIdentifiers.homeScreen.roomName(demoRoom)].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[A11yIdentifiers.homeScreen.roomName(groupRoom)].exists)
        try await attachRootScreenshot(app, name: "CHIICH-store-chats-\(appearance)")

        openSettings(app)
        XCTAssertTrue(control(Control.profile, in: app).exists)
        try await attachRootScreenshot(app, name: "CHIICH-store-settings-\(appearance)")
        closeSettings(app)

        app.buttons[Control.search].tap()
        assertNativeSearch(app, query: demoRoom, expectedRoom: demoRoom)
        try await attachRootScreenshot(app, name: "CHIICH-store-search-\(appearance)")
        closeNativeSearch(app)
        assertChatsAreVisible(app)
    }

    private func assertChatsAreVisible(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons[Control.search].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons[Control.search].isHittable)
    }
    
    private func assertSingleHomeSearch(_ app: XCUIApplication) {
        XCTAssertEqual(app.buttons.matching(identifier: Control.search).count, 1)
        XCTAssertEqual(app.searchFields.count, 0, "Home should only expose its blue native-search entry.")
        XCTAssertEqual(app.switches.count, 0, "The chat filter row belongs in Settings.")
        assertNoTabControls(app)
    }
    
    private func assertNoTabControls(_ app: XCUIApplication) {
        for identifier in [A11yIdentifiers.homeTabs.chats, A11yIdentifiers.homeTabs.spaces, A11yIdentifiers.homeTabs.search] {
            let tab = app.buttons[identifier].firstMatch
            XCTAssertFalse(tab.exists && tab.isHittable, "The old tab/rail entry is still visible: \(identifier)")
        }
    }
    
    private func assertNativeSearch(_ app: XCUIApplication, query: String, expectedRoom: String) {
        let fields = nativeSearchFields(in: app)
        let field = fields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Native search must expose its searchable field.\n\(app.debugDescription)")
        XCTAssertTrue(field.isHittable)
        XCTAssertEqual(fields.count, 1)
        XCTAssertTrue(["Search", "Поиск"].contains(field.placeholderValue ?? ""), "Expected the native search placeholder.")
        dismissKeyboardIntroductionIfNeeded(app)
        field.clearAndTypeText(query, app: app)
        XCTAssertTrue(app.buttons[A11yIdentifiers.searchScreen.roomName(expectedRoom)].waitForExistence(timeout: 5))
        let close = nativeSearchClose(in: app)
        XCTAssertTrue(close.exists && close.isHittable, "Search must have an accessible exit even with its field focused.\n\(app.debugDescription)")
    }
    
    private func nativeSearchFields(in app: XCUIApplication) -> XCUIElementQuery {
        // KeyNavigatingSearchTextField is exported as TextField by the native accessibility tree.
        app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "elementType IN %@", [XCUIElement.ElementType.searchField.rawValue,
                                                                XCUIElement.ElementType.textField.rawValue]))
    }
    
    private func nativeSearchClose(in app: XCUIApplication) -> XCUIElement {
        let explicitClose = app.buttons[Control.closeSearch]
        if explicitClose.exists, explicitClose.isHittable {
            return explicitClose
        }
        // The native iPhone close action replaces the toolbar item while search is active.
        return app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Закрыть"])).firstMatch
    }
    
    private func closeNativeSearch(_ app: XCUIApplication) {
        let close = nativeSearchClose(in: app)
        XCTAssertTrue(close.exists && close.isHittable, "Native search must have an accessible close action.\n\(app.debugDescription)")
        close.tap()
        XCTAssertTrue(nativeSearchFields(in: app).firstMatch.waitForNonExistence(timeout: 5), "Closing search should remove its editable field.")
    }
    
    private func dismissKeyboardIntroductionIfNeeded(_ app: XCUIApplication) {
        let introduction = app.otherElements["UIContinuousPathIntroductionView"]
        guard introduction.waitForExistence(timeout: 1) else { return }
        
        let continueButton = introduction.buttons["Continue"].firstMatch
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(continueButton.isHittable)
        continueButton.tap()
        XCTAssertTrue(introduction.waitForNonExistence(timeout: 5))
    }
    
    private func cancelInlineSearch(_ field: XCUIElement, roomList: XCUIElement, app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Native sidebar search has a clear button, but no separate cancel button.
            let clear = field.buttons.firstMatch
            XCTAssertTrue(clear.exists && clear.isHittable, "Native sidebar search must expose its clear action.\n\(app.debugDescription)")
            clear.tap()
            XCTAssertTrue(app.buttons[A11yIdentifiers.homeScreen.roomName(groupRoom)].waitForExistence(timeout: 5))
            roomList.swipeDown() // Home uses .scrollDismissesKeyboard(.immediately).
        } else {
            // iOS uses an icon beside the field; locate it without guessing a UIKit-localised label.
            let fieldFrame = field.frame
            let close = app.navigationBars.buttons.allElementsBoundByIndex.first { button in
                let frame = button.frame
                return frame.minX >= fieldFrame.maxX && frame.minY < fieldFrame.maxY && frame.maxY > fieldFrame.minY && button.isHittable
            }
            guard let close else {
                XCTFail("Native inline search must expose its close button beside the field.\n\(app.debugDescription)")
                return
            }
            close.tap()
        }
    }
    
    private func openSettings(_ app: XCUIApplication) {
        let avatar = app.buttons[A11yIdentifiers.homeScreen.userAvatar].firstMatch
        XCTAssertTrue(avatar.waitForExistence(timeout: 5))
        avatar.tap()
        XCTAssertTrue(app.buttons[A11yIdentifiers.settingsScreen.done].waitForExistence(timeout: 5))
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label IN %@", ["Settings", "Настройки"]))
        XCTAssertEqual(title.count, 0, "Settings should not repeat its name in a navigation title.")
    }
    
    private func closeSettings(_ app: XCUIApplication) {
        app.buttons[A11yIdentifiers.settingsScreen.done].tap()
        XCTAssertTrue(app.buttons[A11yIdentifiers.settingsScreen.done].waitForNonExistence(timeout: 5))
    }
    
    private func assertSettingsControls(_ app: XCUIApplication) {
        let profile = control(Control.profile, in: app)
        let firstFilter = app.switches[Control.filter("unreads")].firstMatch
        XCTAssertTrue(profile.exists)
        XCTAssertTrue(firstFilter.exists)
        XCTAssertLessThan(profile.frame.maxY, firstFilter.frame.minY)
        
        for name in Control.filterNames {
            let filter = app.switches[Control.filter(name)].firstMatch
            reveal(filter, in: app)
            XCTAssertEqual(filter.value as? String, "0")
        }
        
        let chats = app.switches[Control.chats].firstMatch
        reveal(chats, in: app)
        XCTAssertEqual(chats.value as? String, "1", "Chats should be the initially selected native section.\n\(chats.debugDescription)")
        XCTAssertLessThan(app.switches[Control.filter("lowPriority")].firstMatch.frame.maxY, chats.frame.minY)
        let spaces = app.switches[Control.spaces].firstMatch
        reveal(spaces, in: app)
        XCTAssertEqual(spaces.value as? String, "0")
        XCTAssertLessThan(chats.frame.minY, spaces.frame.minY)
        XCTAssertLessThanOrEqual(chats.frame.maxY, spaces.frame.minY, "Adjacent native rows may share a boundary but must not overlap.")
        reveal(app.buttons[Control.spaceFilter], in: app)
    }
    
    private func assertPeopleFilterApplied(_ app: XCUIApplication) {
        assertChatsAreVisible(app)
        XCTAssertTrue(app.buttons[A11yIdentifiers.homeScreen.roomName(directRoom)].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[A11yIdentifiers.homeScreen.roomName(groupRoom)].waitForNonExistence(timeout: 5))
    }
    
    private func assertSpaceFilterCanBeSelectedAndCleared(_ app: XCUIApplication) {
        openSettings(app)
        let spaceFilter = app.buttons[Control.spaceFilter]
        reveal(spaceFilter, in: app)
        spaceFilter.tap()
        let space = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", firstSpace)).firstMatch
        XCTAssertTrue(space.waitForExistence(timeout: 5))
        space.tap()
        XCTAssertTrue(space.waitForNonExistence(timeout: 5))
        XCTAssertTrue(spaceFilter.label.contains(firstSpace))
        closeSettings(app)
        XCTAssertTrue(app.staticTexts[firstSpace].waitForExistence(timeout: 5))
        
        openSettings(app)
        let clear = app.buttons[Control.clearSpaceFilter]
        reveal(clear, in: app)
        clear.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))
        XCTAssertFalse(spaceFilter.label.contains(firstSpace))
        closeSettings(app)
        XCTAssertTrue(app.staticTexts["CHIICH"].waitForExistence(timeout: 5))
    }
    
    private func assertSpacesAreVisible(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons[A11yIdentifiers.spacesScreen.spaceRoomName(firstSpace)].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[A11yIdentifiers.homeScreen.userAvatar].firstMatch.isHittable)
        let search = app.buttons[Control.search]
        XCTAssertFalse(search.exists && search.isHittable)
    }
    
    private func selectSection(_ identifier: String, in app: XCUIApplication) {
        let section = app.switches[identifier].firstMatch
        reveal(section, in: app)
        section.tap()
        XCTAssertTrue(app.buttons[A11yIdentifiers.settingsScreen.done].waitForNonExistence(timeout: 5))
    }
    
    private func control(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, scrollingUp: Bool = true) {
        for _ in 0..<6 {
            if element.exists, element.isHittable {
                return
            }
            
            // Settings is a Form; swiping the whole iPad app can hit the sheet's backdrop.
            let form = app.collectionViews.firstMatch
            XCTAssertTrue(form.exists && form.isHittable, "Settings must expose its native Form.\n\(app.debugDescription)")
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollingUp ? 0.75 : 0.25))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollingUp ? 0.35 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable, "Could not reveal Settings control \(element.identifier).\n\(app.debugDescription)")
    }
    
    /// Retain full app compositions for review without changing existing snapshot baselines.
    private func attachRootScreenshot(_ app: XCUIApplication, name: String) async throws {
        try await Task.sleep(for: .milliseconds(350))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
