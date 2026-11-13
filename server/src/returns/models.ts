export type WordRule = "globalInclude" | "globalExclude" | "channelInclude" | "channelExclude";
export interface ReturnFilter {
  tags: string[]; folders: string[]; authors: string[]; words: string;
  tagMode: "any" | "all"; authorMode: "any" | "all"; wordMode: "any" | "all";
  createdAfter?: string; createdBefore?: string;
}
export interface ReturnSettings {
  enabled: boolean; notificationsEnabled: boolean; dailyLimit: number; weekdays: number[];
  firstMinute: number; lastMinute: number; minimumIntervalMinutes: number; jitterMinutes: number;
  globalInclude: ReturnFilter; globalExclude: ReturnFilter; channelInclude: ReturnFilter; channelExclude: ReturnFilter;
  boostEnabled: boolean; boostFolderID?: string;
}
export interface CardReturnSettings {cardID: string; notificationsEnabled: boolean; minutes: number[]; weekdays: number[]; deferredUntil?: string}
export interface ReturnSlot {id: string; date: number; explicitCardID?: string}
export interface ReturnReservation {cardID: string; date: number}
export type ReturnReason = "firstReturn" | "longWait" | "preferred" | "coverage" | "explicit" | "noCandidates";
export interface ReturnDecision {cardID?: string; reason: ReturnReason; waitingDays?: number; automaticOrdinal?: number}
export interface ReturnCandidate {
  id: string; createdAt: number; sourceID?: string; folderID?: string; tags: Set<string>; authors: Set<string>;
  isFavorite: boolean; isHidden: boolean; isDeleted: boolean; allowsReturns: boolean; notificationsEnabled: boolean;
  wordMatches: Set<WordRule>; deferredUntil?: number; lastManualOpening?: number; manualOpeningDays: number;
}
export type ReturnErrorCode = "invalidSchedule" | "invalidFilter" | "conflictingExplicitTimes" | "tooManyExplicitTimes";
export class ReturnScheduleError extends Error {
  readonly code: ReturnErrorCode;
  constructor(code: ReturnErrorCode) { super(code); this.code = code; }
}
export function defaultFilter(): ReturnFilter {
  return {tags:[],folders:[],authors:[],words:"",tagMode:"any",authorMode:"any",wordMode:"all"};
}
export function defaultSettings(): ReturnSettings {
  return {enabled:false,notificationsEnabled:false,dailyLimit:3,weekdays:[1,2,3,4,5,6,7],
    firstMinute:570,lastMinute:1230,minimumIntervalMinutes:60,jitterMinutes:30,
    globalInclude:defaultFilter(),globalExclude:defaultFilter(),channelInclude:defaultFilter(),channelExclude:defaultFilter(),boostEnabled:false};
}
