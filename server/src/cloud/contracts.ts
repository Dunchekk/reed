export const recordKinds = ["author","source","folder","tag","card","returnSettings","cardReturn","opening","historyPreference","returnHistory"] as const;
export type RecordKind = typeof recordKinds[number];
export type Payload = Record<string, unknown> | null;
export interface CloudRecord { kind: RecordKind; id: string; version: number; sequence: number; payload: Payload }
export interface Mutation { operationID: string; kind: RecordKind; id: string; baseVersion: number; payload: Payload }
export interface MutationResult { outcome: "applied" | "conflict"; record: CloudRecord }
export interface CloudScope { accountID: string; deviceID: string }
export interface CloudSummary { epoch: string; cards: number; mediaBytes: number; sequence: number; notificationsAvailable: boolean }
export interface CloudPage { epoch: string; records: CloudRecord[]; cursor: number; hasMore: boolean }
export type MediaVariant = "original" | "thumbnail";
export interface MediaPart {size: number; sha256: string}
export interface MediaManifest {id: string; original: MediaPart; thumbnail: MediaPart}
export interface Upload {id: string; originalOffset: number; thumbnailOffset: number; complete: boolean}
export interface Device {id: string; name: string; timeZone: string; isPrimary: boolean; lastSeenAt: string}
export type CloudErrorCode = "invalid_record" | "epoch_changed" | "operation_reused" | "missing_media" | "corrupted_media" | "device_revoked" | "quota_exceeded" | "not_found";
export class CloudError extends Error {
  readonly code: CloudErrorCode;
  readonly statusCode: number;
  constructor(code: CloudErrorCode) {
    const messages: Record<CloudErrorCode, string> = {
      invalid_record:"Проверьте данные синхронизации", epoch_changed:"Облачная библиотека была удалена или заменена. Требуется ваше решение",
      operation_reused:"Нельзя повторить операцию с другим содержимым", missing_media:"Сначала завершите загрузку фотографий",
      corrupted_media:"Фотография не прошла проверку целостности", device_revoked:"Это устройство отключено от облака",
      quota_exceeded:"Достигнут технический лимит хранилища", not_found:"Объект не найден",
    };
    super(messages[code]); this.code=code;
    this.statusCode=code==="not_found"?404:code==="device_revoked"?403:code==="quota_exceeded"?413:code==="invalid_record"?400:409;
  }
}
