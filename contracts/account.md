# Управление аккаунтом

Все контакты подтверждаются у провайдера. UUID аккаунта не меняется. `Account` содержит `id`, `phone` и необязательный `recoveryEmail` (null/отсутствие допустимы). Ошибки и Bearer соответствуют [auth.md](auth.md).

| Метод | Путь | Тело / результат |
| --- | --- | --- |
| GET | `/v1/account/profile` | `{account, deletionAvailable}` |
| POST | `/v1/account/phone/request` | `{value: "+7…"}` → 202 `{retryAt}` |
| POST | `/v1/account/email/request` | `{value: "…@…"}` → 202 `{retryAt}` |
| POST | `/v1/account/phone/verify` | `{code: "123456"}` → `{account, confirmed}` |
| POST | `/v1/account/email/verify` | тот же контракт; `confirmed:false` означает ожидание второго подтверждения |
| POST | `/v1/auth/recovery/request` | без Bearer, `{email}` → 202 `{retryAt}`; существование адреса не раскрывается |
| POST | `/v1/auth/recovery/verify` | без Bearer, `{email, code}` → обычная AuthSession |
| DELETE | `/v1/account` | Bearer → 202 `{status:"deletion_pending"}` |

Цель изменения контакта хранится сервером с привязкой к identity и сроком час. Verify не принимает произвольный новый номер/почту. Восстановление не создаёт новую identity и не переносит локальные файлы.

Удаление сначала блокирует серверный аккаунт и убирает личные поля. Worker завершает удаление identity с повторами после сбоя. Клиент сохраняет локальную фазу удаления до сети, после 202 очищает свою библиотеку и вход. Его поле `deletionProgress` не отправляется серверу, не входит в backup, старые сессии без поля совместимы.
