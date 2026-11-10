# Reed

Персональная библиотека текстовых фрагментов для iPhone. SwiftUI, локальная
SQLite/GRDB, Apple Vision и локальные уведомления. Backend — TypeScript,
Fastify и PostgreSQL.

Сейчас реализуется локальный продуктовый прототип. Облачный архив и APNs —
следующий этап. Реальный SMS-провайдер ещё не подключён.

- [План и архитектура](docs/implementation-plan.md)
- [Принятые решения](docs/decisions.md)
- [Исходная рабочая спецификация](docs/working-spec.md)

## Окружение

Xcode 26+ со Swift 6.1+, iOS Simulator, Node.js 26, npm, XcodeGen,
PostgreSQL в Docker Engine/Colima. Минимальная iOS приложения — 17.
Docker Desktop не требуется. Версии npm и Swift dependencies фиксируются lockfiles.

Для отдельного контейнерного окружения без монтирования пользовательских файлов:

```sh
colima start reed --cpu 2 --memory 2 --disk 12 --mount none --ssh-config=false --activate=false
```

Команды запуска и проверок добавляются вместе с соответствующим рабочим срезом.
Файлы `.env`, локальные базы, сертификаты и снимки пользователей в Git не попадают.
Тесты используют только синтетические данные.

## Разработка

Рабочая ветка — `reed/implementation`. Небольшие последовательные коммиты с
сообщениями `feat:`, `fix:`, `test:`, `build:`, `ci:` или `docs:`. В `main`
изменения автоматически не сливаются.
