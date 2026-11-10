export interface Account {
  id: string;
  phone: string;
}

export interface VerifiedIdentity {
  provider: string;
  subject: string;
  phone: string;
}

export interface AccountRepository {
  findOrCreate(identity: VerifiedIdentity): Promise<Account>;
}
