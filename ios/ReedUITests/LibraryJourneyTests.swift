import XCTest

@MainActor
final class LibraryJourneyTests: XCTestCase {
    func testCreateFindHideRestoreAndReopenCard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-run", UUID().uuidString, "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Архив"].waitForExistence(timeout: 30))
        screenshot("Today", app)
        app.tabBars.buttons["Архив"].tap()
        XCTAssertTrue(app.textFields["archive.search"].waitForExistence(timeout: 10))
        screenshot("Archive", app)
        app.buttons["library.add"].tap()
        let text = app.textViews["editor.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        text.tap(); text.typeText("Journey card")
        let save = app.buttons["editor.save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let search = app.textFields["archive.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("journey")
        let card = app.buttons.containing(.staticText, identifier: "Journey card").firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        XCTAssertTrue(app.buttons["Действия с карточкой"].waitForExistence(timeout: 10))
        screenshot("Card", app)
        app.buttons["Действия с карточкой"].tap(); app.buttons["Скрыть"].tap()
        app.tabBars.buttons["Настройки"].tap()
        app.buttons["Скрытые карточки"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10)); card.tap()
        app.buttons["Действия с карточкой"].tap(); app.buttons["Показать в архиве"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.tabBars.buttons["Архив"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Архив"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        app.tabBars.buttons["Лента"].tap()
        screenshot("Feed", app)
        app.tabBars.buttons["Настройки"].tap()
        app.buttons["Возвращения"].tap()
        XCTAssertTrue(app.switches["Возвращать карточки"].waitForExistence(timeout: 10))
        screenshot("Returns", app)
        let include = app.buttons["Что включать"]
        reveal(include, in: app); include.tap()
        let words = app.descendants(matching: .any).matching(identifier: "return.filter.words").firstMatch
        reveal(words, in: app); words.tap(); words.typeText("journey")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let saveSettings = app.buttons["Сохранить настройки"]
        reveal(saveSettings, in: app); saveSettings.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["Возвращения"].tap()
        reveal(include, in: app); include.tap()
        reveal(words, in: app)
        XCTAssertEqual(words.value as? String, "journey")
    }
    func testDraftSurvivesRelaunchAndCapturePreferencePersists() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ui-test-run", UUID().uuidString, "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        XCTAssertTrue(app.buttons["library.add"].waitForExistence(timeout: 30))
        app.buttons["library.add"].tap()
        let toggle = app.switches["editor.savePhotos"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); toggle.tap()
        let text = app.textViews["editor.text"]
        reveal(text, in: app); text.tap(); text.typeText("Persistent draft")
        app.buttons["Закрыть"].tap()
        XCTAssertTrue(app.buttons["today.drafts"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["today.drafts"].waitForExistence(timeout: 30)); app.buttons["today.drafts"].tap()
        let draft = app.buttons.containing(.staticText, identifier: "Persistent draft").firstMatch
        XCTAssertTrue(draft.waitForExistence(timeout: 10)); draft.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(text.value as? String, "Persistent draft")
        screenshot("Draft editor", app)
        app.buttons["editor.save"].tap()
        XCTAssertTrue(app.staticTexts["Нет черновиков"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Архив"].tap()
        XCTAssertTrue(app.buttons["archive.manage"].waitForExistence(timeout: 10)); app.buttons["archive.manage"].tap()
        XCTAssertTrue(app.switches["Только без карточек"].waitForExistence(timeout: 10))
        screenshot("Library management", app)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<16 {
            if element.exists && element.isHittable { return }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.65))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
