import type {MediaPart, MediaVariant} from "../contracts.ts";

export interface ObjectScope {accountID: string; epoch: string}
/** Paths and public URLs never cross this boundary. The store is private to the server. */
export interface ObjectStore {
  inspect(scope: ObjectScope, area: "upload" | "media", id: string, variant: MediaVariant): Promise<MediaPart | undefined>;
  append(scope: ObjectScope, uploadID: string, variant: MediaVariant, offset: number, bytes: Buffer): Promise<void>;
  publish(scope: ObjectScope, uploadID: string, mediaID: string, variant: MediaVariant, expected: MediaPart): Promise<void>;
  read(scope: ObjectScope, mediaID: string, variant: MediaVariant, offset: number, count: number): Promise<Buffer>;
  removeMedia(scope: ObjectScope, id: string): Promise<void>;
  removeOrphans(scope: ObjectScope, uploads: Set<string>, media: Set<string>, olderThan: Date): Promise<void>;
  removeUpload(scope: ObjectScope, id: string): Promise<void>;
  removeEpoch(scope: ObjectScope): Promise<void>;
  removeAccount(accountID: string): Promise<void>;
}
