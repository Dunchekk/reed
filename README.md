# Reed

Персональная библиотека текстовых фрагментов для iPhone. SwiftUI, локальная
SQLite/GRDB, Apple Vision и локальные уведомления. Backend — TypeScript,
Fastify и PostgreSQL.

Реализован локальный продуктовый прототип: архив, поиск, карточки с фото/OCR,
Главная, Лента, история и план возвращений. Облачный архив и APNs —
следующий этап. Реальный SMS-провайдер ещё не подключён.

- [Запуск iOS](ios/README.md) · [Сервер](server/README.md) · [Тесты ядра](ios/ReedCore/Tests/README.md)
- [План и архитектура](docs/implementation-plan.md)
- [Принятые решения](docs/decisions.md)
- [Проверки и три прохода review](docs/validation.md) · [Снимки экранов](docs/screenshots/README.md)
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
Данные тестовых аккаунтов откатываются транзакцией.

Проект открывается через `ios/Reed.xcodeproj`; `ios/project.yml` — источник
конфигурации проекта. После изменения списка файлов выполнить `make ios-project`.

Файлы `.env`, локальные базы, сертификаты и снимки пользователей в Git не попадают.
Тесты используют только синтетические данные.

## Разработка

Рабочая ветка — `reed/implementation`. Небольшие последовательные коммиты с
сообщениями `feat:`, `fix:`, `test:`, `build:`, `ci:` или `docs:`. В `main`
изменения сливаются после завершения реализации, независимого review и проверок;
отдельные коммиты сохраняются.
