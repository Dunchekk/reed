# Проверки этапа «Облако и второй iPhone»

Ветка `reed/cloud-sync`, база `c23a8d4`. Работа локальная; push, PR и merge не выполнялись.

## Выполнено до независимого ревью

- `TEST_DATABASE_URL=... make server-check`: typecheck, 44 Node-теста с PostgreSQL, JS build — успешно, без skipped.
- `swift test --package-path ios/ReedCore --scratch-path .local/swift-build --disable-sandbox`: 84 теста Swift Testing — успешно; отдельные opt-in integration/performance сценарии не выполняются этим запуском.
- `TEST_DATABASE_URL=... scripts/cloud-e2e.sh`: успешно. Два независимых SQLite-клиента через настоящий HTTP/PostgreSQL: фото 700 KB, потерянный ответ, восстановление outbox, конфликт правок/сохранение обеих, tombstone, смена epoch и локальная копия.
- Общие fixtures Swift/TS: jitter, первый/пропущенный час DST, индивидуальные слоты, переполнение квоты, 72 часа, история, охват и источники — успешно.
- `xcodebuild ... -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build-for-testing`: успешно; новые экраны и AppDelegate компилируются вместе с тестовыми targets.
- `make ios-project`, проверка diff: конфигурация воспроизводима; секретов и пользовательских данных в коммитах нет.

## Внешние границы

Figma просмотрена через интеграцию: экран «Данные и синхронизация» `383:8972` в файле `4TxAyioeWNLLl9e0FOeqOb`. Использованы цвета, размеры и структура; шрифт — системный SF. Новые состояния конфликта/устройств дополнены в стиле приложения. В этой среде нет установленного Simulator runtime: новые экраны не запускались, визуальная проверка на iPhone не заявляется. Старые screenshots относятся к прежним этапам.

Реальные APNs, SMS, SMTP, HTTPS deployment, TestFlight и испытания второго физического iPhone не выполнялись. APNs проверен fake-провайдером; без ключей сервер сообщает недоступность доставки. Файловый ObjectStore предназначен для одного серверного узла; shared storage и compaction долгоживущего журнала — отдельные инфраструктурные задачи. Прототип не обещает exactly-once доставку APNs: неоднозначный ответ не повторяется автоматически.

## Независимое ревью

Будет заполнено по фактическому результату Astra High после завершения реализации и проверок.
