# Скрипты разработки

`ios-ui-test.sh` выбирает доступный iPhone Simulator, загружает его и запускает
схему Reed с XCUITest. Отсутствие runtime — ошибка с объяснением, а не успешный skip.
Результат и снимки находятся в `.local/UITests.xcresult`.

`generate-app-icon.swift` рисует простую собственную иконку средствами AppKit/Core
Graphics. Это воспроизводимый исходник растрового AppIcon, без внешнего сервиса.
