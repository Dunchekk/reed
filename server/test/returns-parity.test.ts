import test from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import {ZonedCalendar} from "../src/returns/calendar.ts";
import {planSlots} from "../src/returns/slots.ts";
import {PreparedCandidates,selectReturn} from "../src/returns/selector.ts";
import type {ReturnCandidate,ReturnDecision,ReturnSettings,ReturnSlot,CardReturnSettings,WordRule} from "../src/returns/models.ts";
interface SlotFixture {name:string;day:string;timeZone:string;seed:string;settings:ReturnSettings;explicit:CardReturnSettings[];expectedSlots?:Array<{id:string;date:string;explicitCardID?:string}>;expectedError?:string}
interface CandidateFixture extends Partial<Omit<ReturnCandidate,"createdAt"|"tags"|"authors"|"wordMatches"|"deferredUntil"|"lastManualOpening">> {
  id:string;createdAt:string;tags?:string[];authors?:string[];wordMatches?:WordRule[];deferredUntil?:string;lastManualOpening?:string;
}
interface SelectionFixture {name:string;slot:Omit<ReturnSlot,"date"> & {date:string};settings:ReturnSettings;candidates:CandidateFixture[];reservations:Array<{cardID:string;date:string}>;previousAutomaticOrdinal:number;historyEnabled:boolean;sourcesUsedToday:string[];expected:ReturnDecision}
const fixtures = JSON.parse(readFileSync(new URL("../../contracts/fixtures/returns.json",import.meta.url),"utf8")) as {slots:SlotFixture[];selections:SelectionFixture[]};
for (const fixture of fixtures.slots) test(`Swift parity: slots / ${fixture.name}`,() => {
  const calendar = new ZonedCalendar(fixture.timeZone);
  const generate = () => planSlots(calendar.components(Date.parse(fixture.day)),BigInt(fixture.seed),fixture.settings,fixture.explicit,calendar)
    .map(slot => ({...slot,date:new Date(slot.date).toISOString()}));
  if (fixture.expectedError) assert.throws(generate,{message:fixture.expectedError});
  else assert.deepEqual(generate(),fixture.expectedSlots);
});
for (const fixture of fixtures.selections) test(`Swift parity: selection / ${fixture.name}`,() => {
  const candidates:ReturnCandidate[] = fixture.candidates.map(card => ({...card,createdAt:Date.parse(card.createdAt),
    tags:new Set(card.tags),authors:new Set(card.authors),wordMatches:new Set(card.wordMatches),
    isFavorite:card.isFavorite ?? false,isHidden:card.isHidden ?? false,isDeleted:card.isDeleted ?? false,
    allowsReturns:card.allowsReturns ?? true,notificationsEnabled:card.notificationsEnabled ?? true,manualOpeningDays:card.manualOpeningDays ?? 0,
    ...(card.deferredUntil ? {deferredUntil:Date.parse(card.deferredUntil)} : {}),
    ...(card.lastManualOpening ? {lastManualOpening:Date.parse(card.lastManualOpening)} : {})} as ReturnCandidate));
  const result = selectReturn({...fixture.slot,date:Date.parse(fixture.slot.date)},new PreparedCandidates(candidates,fixture.settings),fixture.settings,
    fixture.reservations.map(item => ({...item,date:Date.parse(item.date)})),fixture.previousAutomaticOrdinal,fixture.historyEnabled,new Set(fixture.sourcesUsedToday));
  assert.deepEqual(result,fixture.expected);
});
