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
        text.tap(); text.typeText("Journey fragment about architecture and reading.")
        let title = app.textFields["editor.title"]
        for _ in 0..<4 where !title.isHittable { app.swipeUp() }
        title.tap(); title.typeText("Journey card")
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
    }
    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
