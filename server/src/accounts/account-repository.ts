export interface Account {
  id: string;
  phone: string;
  recoveryEmail?: string | null;
}

export interface VerifiedIdentity {
  provider: string;
  subject: string;
  phone: string;
  recoveryEmail?: string | null;
}

export interface AccountRepository {
  findOrCreate(identity: VerifiedIdentity): Promise<Account>;
}
