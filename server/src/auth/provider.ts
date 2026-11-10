import type { VerifiedIdentity } from "../accounts/account-repository.ts";

export interface ProviderSession {
  identity: VerifiedIdentity;
  accessToken: string;
  refreshToken: string;
  expiresAt: string;
}

export interface AuthenticationProvider {
  requestCode(phone: string): Promise<{ retryAt: string }>;
  verifyCode(phone: string, code: string): Promise<ProviderSession>;
  refresh(refreshToken: string): Promise<ProviderSession>;
  authenticate(accessToken: string): Promise<VerifiedIdentity>;
  revoke(accessToken: string): Promise<void>;
}

export type AuthErrorCode = "invalid_request" | "invalid_code" | "unauthorized"
  | "rate_limited" | "provider_unavailable";

export class AuthError extends Error {
  readonly code: AuthErrorCode;
  readonly statusCode: number;
  readonly retryAt: string | undefined;

  constructor(code: AuthErrorCode, retryAt?: string) {
    const details: Record<AuthErrorCode, [number, string]> = {
      invalid_request: [400, "Проверьте введённые данные"],
      invalid_code: [401, "Код неверен или истёк. Запросите новый код"],
      unauthorized: [401, "Войдите в аккаунт снова"],
      rate_limited: [429, "Слишком много попыток. Попробуйте позже"],
      provider_unavailable: [503, "Сервис входа временно недоступен"],
    };
    const [status, message] = details[code];
    super(message);
    this.code = code;
    this.statusCode = status;
    this.retryAt = retryAt;
  }
}
