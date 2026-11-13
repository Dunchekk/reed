# Проверки HTTP

URLProtocol перехватывает запросы внутри тестового URLSession. Проверяем реальное кодирование маршрутов и заголовков, повтор после 401 и сохранение тела мутации. Сеть и backend для этих тестов не нужны. Серверный протокол отдельно проверяется через Fastify inject и PostgreSQL.

Запуск: `swift test --package-path ios/ReedCore --filter CloudHTTPTests`.
