import {ZonedCalendar} from "./calendar.ts";
import type {LocalDay} from "./calendar.ts";
import {ReturnScheduleError} from "./models.ts";
import type {CardReturnSettings,ReturnSettings,ReturnSlot} from "./models.ts";
import {validateSettings} from "./policy.ts";

export function stableHash(text: string, startingAt = 14695981039346656037n): bigint {
  let hash = startingAt;
  for (const byte of Buffer.from(text,"utf8")) hash = BigInt.asUintN(64,(hash^BigInt(byte))*1099511628211n);
  return hash;
}
export function planSlots(day: LocalDay, seed: bigint, settings: ReturnSettings, explicit: CardReturnSettings[], calendar: ZonedCalendar): ReturnSlot[] {
  validateSettings(settings);
  const weekday = calendar.weekday(day);
  if (!settings.enabled || !settings.notificationsEnabled || !settings.weekdays.includes(weekday)) return [];
  const key = calendar.key(day), interval = settings.minimumIntervalMinutes*60000, chosen: ReturnSlot[] = [];
  const available = (time: number) => chosen.every(slot => Math.abs(slot.date-time) >= interval);
  for (const rule of [...explicit].sort((a,b) => a.cardID.toUpperCase() < b.cardID.toUpperCase() ? -1 : a.cardID === b.cardID ? 0 : 1)) {
    if (!rule.notificationsEnabled) continue;
    if (rule.minutes.length > 10 || new Set(rule.minutes).size !== rule.minutes.length ||
        !rule.minutes.every(minute => Number.isInteger(minute) && minute >= 0 && minute <= 1439) ||
        !rule.weekdays.every(value => Number.isInteger(value) && value >= 1 && value <= 7)) throw new ReturnScheduleError("invalidSchedule");
    const deferred = rule.deferredUntil ? Date.parse(rule.deferredUntil) : undefined;
    if (deferred !== undefined && !Number.isFinite(deferred)) throw new ReturnScheduleError("invalidSchedule");
    if (deferred !== undefined && calendar.dayKey(deferred) === key) {
      if (!available(deferred)) throw new ReturnScheduleError("conflictingExplicitTimes");
      chosen.push({id:`${key}.d.${rule.cardID.toUpperCase()}.${Math.trunc(deferred/1000)}`,date:deferred,explicitCardID:rule.cardID});
    }
    if (!rule.weekdays.includes(weekday)) continue;
    for (const minute of [...rule.minutes].sort((a,b) => a-b)) {
      const time = calendar.date(day,minute);
      if (time === undefined || (deferred !== undefined && time <= deferred)) continue;
      if (!available(time)) throw new ReturnScheduleError("conflictingExplicitTimes");
      chosen.push({id:`${key}.e.${rule.cardID.toUpperCase()}.${minute}`,date:time,explicitCardID:rule.cardID});
    }
  }
  if (chosen.length > settings.dailyLimit) throw new ReturnScheduleError("tooManyExplicitTimes");
  const count = settings.dailyLimit, margin = Math.min(settings.jitterMinutes,Math.trunc((settings.lastMinute-settings.firstMinute)/2));
  const first = settings.firstMinute+margin, last = settings.lastMinute-margin;
  for (let index = 0; index < count && chosen.length < count; index++) {
    const center = count === 1 ? Math.trunc((first+last)/2) : first+Math.trunc((last-first)*index/(count-1));
    const random = Number(stableHash(`${seed}.${index}`)%BigInt(settings.jitterMinutes*2+1))-settings.jitterMinutes;
    const preferred = Math.max(settings.firstMinute,Math.min(settings.lastMinute,center+random));
    const minutes = Array.from({length:settings.lastMinute-settings.firstMinute+1},(_,offset) => settings.firstMinute+offset)
      .sort((a,b) => Math.abs(a-preferred)-Math.abs(b-preferred) || a-b);
    for (const minute of minutes) {
      const time = calendar.date(day,minute);
      if (time !== undefined && available(time)) { chosen.push({id:`${key}.a.${index}.${Math.trunc(time/1000)}`,date:time}); break; }
    }
  }
  return chosen.sort((a,b) => a.date-b.date || (a.id < b.id ? -1 : a.id === b.id ? 0 : 1));
}
