import {ReturnScheduleError} from "./models.ts";
import type {ReturnCandidate,ReturnFilter,ReturnSettings,WordRule} from "./models.ts";

export function tokens(text: string): string[] {
  return text.normalize("NFC").toLocaleLowerCase("ru-RU").replaceAll("ё","е").match(/[\p{L}\p{N}]+/gu) ?? [];
}
export function validateSettings(settings: ReturnSettings): void {
  const {dailyLimit,firstMinute,lastMinute,minimumIntervalMinutes,jitterMinutes} = settings;
  const inRange = (value: number, min: number, max: number) => Number.isInteger(value) && value >= min && value <= max;
  if (!inRange(dailyLimit,1,10) || !settings.weekdays.every(day => inRange(day,1,7)) ||
      !inRange(firstMinute,0,1439) || !inRange(lastMinute,firstMinute,1439) ||
      !inRange(minimumIntervalMinutes,60,720) || !inRange(jitterMinutes,0,60) ||
      (dailyLimit-1)*minimumIntervalMinutes > lastMinute-firstMinute) throw new ReturnScheduleError("invalidSchedule");
  for (const filter of [settings.globalInclude,settings.globalExclude,settings.channelInclude,settings.channelExclude]) {
    if (filter.tags.length > 100 || filter.folders.length > 100 || filter.authors.length > 100 ||
        Buffer.byteLength(filter.words) > 8192 || tokens(filter.words).length > 64 ||
        (filter.createdAfter && filter.createdBefore && Date.parse(filter.createdAfter) >= Date.parse(filter.createdBefore))) throw new ReturnScheduleError("invalidFilter");
  }
}
function compileFilter(filter: ReturnFilter, rule: WordRule): {empty: boolean; matches: (card: ReturnCandidate) => boolean} {
  const after = filter.createdAfter ? Date.parse(filter.createdAfter) : undefined;
  const before = filter.createdBefore ? Date.parse(filter.createdBefore) : undefined;
  const hasWords = tokens(filter.words).length > 0;
  const match = (requested: string[], actual: Set<string>, mode: "any" | "all") => requested.length === 0 ||
    (mode === "any" ? requested.some(id => actual.has(id)) : requested.every(id => actual.has(id)));
  return {
    empty: !filter.tags.length && !filter.folders.length && !filter.authors.length && !hasWords && after === undefined && before === undefined,
    matches: card => match(filter.tags,card.tags,filter.tagMode) && (!filter.folders.length || (!!card.folderID && filter.folders.includes(card.folderID))) &&
      match(filter.authors,card.authors,filter.authorMode) && (!hasWords || card.wordMatches.has(rule)) &&
      (after === undefined || card.createdAt >= after) && (before === undefined || card.createdAt < before),
  };
}
export function admission(settings: ReturnSettings): (card: ReturnCandidate, explicit: boolean) => boolean {
  const globalInclude = compileFilter(settings.globalInclude,"globalInclude"), globalExclude = compileFilter(settings.globalExclude,"globalExclude");
  const channelInclude = compileFilter(settings.channelInclude,"channelInclude"), channelExclude = compileFilter(settings.channelExclude,"channelExclude");
  return (card,explicit) => settings.enabled && settings.notificationsEnabled && card.allowsReturns && card.notificationsEnabled && !card.isDeleted && !card.isHidden &&
    (explicit || (globalInclude.matches(card) && channelInclude.matches(card) && (globalExclude.empty || !globalExclude.matches(card)) && (channelExclude.empty || !channelExclude.matches(card))));
}
