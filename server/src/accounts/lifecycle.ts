import type { Account, VerifiedIdentity } from "./account-repository.ts";
import type { ProviderSession } from "../auth/provider.ts";
import { AuthError } from "../auth/provider.ts";

export type ContactKind = "phone" | "email";
export interface AccountLifecycleProvider {
  readonly deletionAvailable: boolean;
  requestContact(token: string, kind: ContactKind, value: string): Promise<{ retryAt: string }>;
  verifyContact(token: string, kind: ContactKind, value: string, code: string): Promise<VerifiedIdentity>;
  requestRecovery(email: string): Promise<{ retryAt: string }>;
  verifyRecovery(email: string, code: string): Promise<ProviderSession>;
  deleteIdentity(subject: string): Promise<void>;
}
export interface AccountLifecycleRepository {
  rememberContact(identity: VerifiedIdentity, kind: ContactKind, value: string): Promise<void>;
  pendingContact(identity: VerifiedIdentity, kind: ContactKind): Promise<string | undefined>;
  beginDeletion(identity: VerifiedIdentity): Promise<void>;
  pendingDeletions(): Promise<{ id: string; provider: string; subject: string }[]>;
  finishDeletion(id: string): Promise<void>;
}
export interface AccountProfile { account: Account; deletionAvailable: boolean }

/** Durable retry loop: the local account is blocked before the remote identity is removed. */
export class AccountDeletionWorker {
  private running: Promise<void> | undefined;
  private readonly repository: AccountLifecycleRepository;
  private readonly provider: AccountLifecycleProvider;
  private readonly cleanup: ((accountID:string)=>Promise<void>)|undefined;
  private readonly providerName: string;
  constructor(repository: AccountLifecycleRepository, provider: AccountLifecycleProvider, providerName: string, cleanup?: (accountID:string)=>Promise<void>) {
    this.repository = repository; this.provider = provider; this.providerName = providerName; this.cleanup = cleanup;
  }
  run(): Promise<void> {
    if (this.running) return this.running;
    this.running = this.process().finally(() => { this.running = undefined; });
    return this.running;
  }
  private async process(): Promise<void> {
    if (!this.provider.deletionAvailable) return;
    let failed = false;
    for (const job of await this.repository.pendingDeletions()) {
      if (job.provider !== this.providerName) continue;
      try {
        await this.cleanup?.(job.id);
        await this.provider.deleteIdentity(job.subject);
        await this.repository.finishDeletion(job.id);
      } catch { failed = true; }
    }
    if (failed) throw new AuthError("provider_unavailable");
  }
}
export function ensureSameIdentity(before: VerifiedIdentity, after: VerifiedIdentity): void {
  if (before.provider !== after.provider || before.subject !== after.subject) throw new AuthError("unauthorized");
}
