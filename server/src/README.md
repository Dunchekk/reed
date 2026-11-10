# Серверные модули

`app.ts` — фабрика Fastify с безопасным обработчиком ошибок. `index.ts` — единственное
место запуска listener и сборки provider/pool/repository. `config.ts` валидирует env
и запрещает development auth в production.

`auth` отделяет HTTP-схемы и rate limit от провайдеров. Development adapter нужен
только для синтетических номеров; Supabase adapter отправляет запросы без общего
состояния сессий. `accounts` хранит стабильное соответствие provider subject → UUID.
`database` отвечает за соединения и атомарные миграции с checksum/advisory lock.

Облачная библиотека и серверный выбор возвращений сюда пока не входят. Когда они
появятся, их контракты должны сохранять принятые правила поиска и ownership аккаунта.
