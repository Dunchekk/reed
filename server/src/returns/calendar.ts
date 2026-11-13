export interface LocalDay {year: number; month: number; day: number}

/** Gregorian local-day operations with explicit first-occurrence / next-valid-minute DST semantics. */
export class ZonedCalendar {
  readonly timeZone: string;
  private readonly formatter: Intl.DateTimeFormat;
  private readonly timelines = new Map<string,Map<number,number>>();
  constructor(timeZone: string) {
    this.timeZone = timeZone;
    this.formatter = new Intl.DateTimeFormat("en-GB-u-ca-gregory-nu-latn", {timeZone,year:"numeric",month:"2-digit",day:"2-digit",hour:"2-digit",minute:"2-digit",hourCycle:"h23"});
  }
  components(date: number): LocalDay & {hour: number; minute: number} {
    const parts = Object.fromEntries(this.formatter.formatToParts(date).filter(part => part.type !== "literal").map(part => [part.type,Number(part.value)]));
    return {year:parts.year!,month:parts.month!,day:parts.day!,hour:parts.hour!,minute:parts.minute!};
  }
  key(day: LocalDay): string { return `${day.year}-${day.month}-${day.day}@${this.timeZone}`; }
  dayKey(date: number): string { return this.key(this.components(date)); }
  weekday(day: LocalDay): number { return new Date(this.utcDay(day)).getUTCDay()+1; }
  addingDays(day: LocalDay, count: number): LocalDay {
    const date = new Date(this.utcDay(day)+count*86400000);
    return {year:date.getUTCFullYear(),month:date.getUTCMonth()+1,day:date.getUTCDate()};
  }
  date(day: LocalDay, minute: number): number | undefined {
    const timeline = this.timeline(day);
    for (let next = minute; next < 1440; next++) { const value = timeline.get(next); if (value !== undefined) return value; }
    return undefined;
  }
  private utcDay(day: LocalDay): number {
    const date = new Date(0); date.setUTCFullYear(day.year,day.month-1,day.day); date.setUTCHours(0,0,0,0); return date.getTime();
  }
  private timeline(day: LocalDay): Map<number,number> {
    const key = this.key(day), cached = this.timelines.get(key);
    if (cached) return cached;
    const values = new Map<number,number>(), midnight = this.utcDay(day);
    for (let time = midnight-18*3600000; time <= midnight+42*3600000; time += 60000) {
      const local = this.components(time);
      if (local.year !== day.year || local.month !== day.month || local.day !== day.day) continue;
      const minute = local.hour*60+local.minute;
      if (!values.has(minute)) values.set(minute,time);
    }
    this.timelines.set(key,values); return values;
  }
}
