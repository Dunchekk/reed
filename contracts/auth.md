# Reed HTTP API v1: authentication

JSON uses camelCase. Dates are UTC ISO 8601 strings. Account IDs are UUID strings.
Phone numbers are normalized `+7` followed by ten ASCII digits. Requests use
`Content-Type: application/json`; authenticated requests use `Authorization:
Bearer <accessToken>`. Tokens are opaque to the client and never used as account IDs.

| Method/path | Body | Successful response |
| --- | --- | --- |
| `POST /v1/auth/otp` | `{ "phone": "+70000000001" }` | `202 { "retryAt": "..." }` |
| `POST /v1/auth/verify` | `{ "phone": "+70000000001", "code": "123456" }` | `200 Session` |
| `POST /v1/auth/refresh` | `{ "refreshToken": "..." }` | `200 Session` |
| `POST /v1/auth/logout` | none, bearer required | `204` |
| `GET /v1/account` | none, bearer required | `200 Account` |

```json
{
  "account": { "id": "11111111-1111-4111-8111-111111111111", "phone": "+70000000001" },
  "accessToken": "opaque-access-token",
  "refreshToken": "opaque-refresh-token",
  "expiresAt": "2026-11-10T20:00:00.000Z"
}
```

Errors have `{ "error": { "code": "...", "message": "...", "retryAt": "..." } }`.
`retryAt` is optional. The client acts on `code`, not on message text.

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `invalid_request` | Body, phone or code format is invalid |
| 401 | `invalid_code` | Code is invalid, expired, consumed or unavailable |
| 401 | `unauthorized` | Access/refresh token is invalid or expired |
| 429 | `rate_limited` | Resend or attempt limit; respect retryAt when present |
| 503 | `provider_unavailable` | Provider/network failure; no fallback authentication |
| 500 | `internal_error` | Unexpected server failure, without internal details |

OTP request success does not prove delivery. Verification proves the provider
identity and maps it to a stable Reed account. Refresh rotates credentials when
the provider does. Logout revokes the provider refresh session when reachable;
already issued provider access tokens may remain valid until their expiry. Local
logout clears Keychain access and notifications even if the network is unavailable.
An expired credential does not erase an already confirmed local library.

Development authentication accepts only synthetic `+70000000000`…`+70000000099`
numbers and code `123456`. It must be selected explicitly for development/test,
never production. Challenges live for five minutes, resend waits 60 seconds,
verification allows five attempts. Tokens are random, expiring and revocable;
the fixed code is not accepted without an issued challenge. Development sessions
may expire on server restart. Real SMS and delivery guarantees require a provider.

This stage sends no card text, photos, search queries or opening history to the
server. Do not include request bodies, phone numbers or tokens in application logs.
