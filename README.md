# Reed

Персональная библиотека текстовых фрагментов для iPhone. SwiftUI, локальная
SQLite/GRDB, Apple Vision и локальные уведомления. Backend — TypeScript,
Fastify и PostgreSQL.

Реализован локальный продуктовый прототип: архив, поиск, карточки с фото/OCR,
Главная, Лента, история и план возвращений. Второй этап добавляет несколько фото,
фрагменты OCR, черновики, управление справочниками, резервные копии и аккаунт. Третий этап добавляет
облако, две офлайн-реплики, возобновляемый перенос фото, конфликты и общий план возвращений.
Адаптер APNs готов к настройке; реальные APNs/SMS и выпуск приложения не подключены.

- [Запуск iOS](ios/README.md) · [Сервер](server/README.md) · [Тесты ядра](ios/ReedCore/Tests/README.md)
- [План и архитектура](docs/implementation-plan.md)
- [Принятые решения](docs/decisions.md)
- [Проверки и три прохода review](docs/validation.md) · [Снимки экранов](docs/screenshots/README.md)
- [Второй этап: план](docs/library-tools-plan.md) · [Проверки второго этапа](docs/library-tools-validation.md)
- [Облако: план](docs/cloud-sync-plan.md) · [Протокол](contracts/cloud.md) · [Проверки](docs/cloud-sync-validation.md)
- [Исходная рабочая спецификация](docs/working-spec.md)

## Окружение

Xcode 26+ со Swift 6.1+, iOS Simulator, Node.js 26, npm, XcodeGen,
PostgreSQL в Docker Engine/Colima. Минимальная iOS приложения — 17.
Docker Desktop не требуется. Версии npm и Swift dependencies фиксируются lockfiles.

Для отдельного контейнерного окружения без монтирования пользовательских файлов:

```sh
colima start reed --cpu 2 --memory 2 --disk 12 --mount none --ssh-config=false --activate=false
```

```sh
npm ci
docker --context colima-reed compose up -d --wait
cp server/.env.example server/.env
npm run db:migrate --workspace server
npm run dev --workspace server
```

Проверки:

```sh
make swift-test
make ios-build
TEST_DATABASE_URL=postgres://reed_dev:reed_local_only@127.0.0.1:55432/reed_dev make server-check
```

PostgreSQL-тест пропускается, если `TEST_DATABASE_URL` не задан. Для полной
проверки переменная обязательна; CI всегда запускает этот тест с настоящей БД.
Данные тестовых аккаунтов откатываются транзакцией или удаляются в `finally`.
Сквозная проверка двух Swift-клиентов: `TEST_DATABASE_URL=... scripts/cloud-e2e.sh`.

Проект открывается через `ios/Reed.xcodeproj`; `ios/project.yml` — источник
конфигурации проекта. После изменения списка файлов выполнить `make ios-project`.

Файлы `.env`, локальные базы, сертификаты и снимки пользователей в Git не попадают.
Тесты используют только синтетические данные.

## Разработка

Текущая рабочая ветка — `reed/cloud-sync`. По решению пользователя новые
коммиты пока остаются локально; main не обновляется. Небольшие последовательные коммиты с
сообщениями `feat:`, `fix:`, `test:`, `build:`, `ci:` или `docs:`. Этот этап не
отправляется на GitHub, PR не создаётся, merge не выполняется.
