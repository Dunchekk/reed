import type {ReturnCandidate,ReturnDecision,ReturnReservation,ReturnSettings,ReturnSlot} from "./models.ts";
import {admission} from "./policy.ts";
import {stableHash} from "./slots.ts";

export const cooldown = 72*3600000;
export class PreparedCandidates {
  readonly automatic: Array<{card:ReturnCandidate;key:string}>;
  readonly explicit = new Map<string,ReturnCandidate>();
  constructor(candidates: ReturnCandidate[], settings: ReturnSettings) {
    const admits = admission(settings);
    this.automatic = candidates.filter(card => admits(card,false)).map(card => ({card,key:card.id.toUpperCase()}));
    for (const card of candidates) if (admits(card,true) && !this.explicit.has(card.id)) this.explicit.set(card.id,card);
  }
}
export function selectReturn(slot: ReturnSlot, prepared: PreparedCandidates, settings: ReturnSettings, reservations: ReturnReservation[],
  previousAutomaticOrdinal: number, historyEnabled: boolean, sourcesUsedToday = new Set<string>()): ReturnDecision {
  if (slot.explicitCardID) {
    const card = prepared.explicit.get(slot.explicitCardID);
    return card ? {cardID:card.id,reason:"explicit"} : {reason:"noCandidates"};
  }
  const blocked = new Set(reservations.filter(event => Math.abs(event.date-slot.date) < cooldown).map(event => event.cardID));
  const last = new Map<string,number>();
  for (const event of reservations) if (event.date <= slot.date) last.set(event.cardID,Math.max(last.get(event.cardID) ?? -Infinity,event.date));
  const ordinal = previousAutomaticOrdinal+1, coverage = ordinal%5 === 0, prefix = stableHash(slot.id);
  let winner: {entry:{card:ReturnCandidate;key:string};wait:number;score:number;never:boolean;boosted:boolean;hash?:bigint} | undefined;
  for (const entry of prepared.automatic) {
    const card = entry.card;
    if (blocked.has(card.id) || (card.deferredUntil !== undefined && slot.date < card.deferredUntil)) continue;
    const waiting = Math.max(0,(slot.date-(last.get(card.id) ?? card.createdAt))/86400000);
    const boosted = settings.boostEnabled && (settings.boostFolderID ? card.folderID === settings.boostFolderID : card.isFavorite);
    let score = Math.max(0.1,waiting)*(boosted ? 2 : 1);
    if (historyEnabled) {
      const unseen = Math.min(1,Math.max(0,(slot.date-(card.lastManualOpening ?? card.createdAt))/(90*86400000)));
      score += unseen+Math.min(3,card.manualOpeningDays)*0.2;
    }
    if (card.sourceID && !sourcesUsedToday.has(card.sourceID)) score += 0.25;
    const never = !last.has(card.id);
    let wins = !winner, hash: bigint | undefined;
    if (winner) {
      if (coverage && never !== winner.never) wins = never;
      else if (coverage && waiting !== winner.wait) wins = waiting > winner.wait;
      else if (!coverage && score !== winner.score) wins = score > winner.score;
      else {
        hash = stableHash(entry.key,prefix);
        const previous = winner.hash ?? stableHash(winner.entry.key,prefix); winner.hash = previous;
        wins = hash === previous ? entry.key < winner.entry.key : hash < previous;
      }
    }
    if (wins) winner = {entry,wait:waiting,score,never,boosted,...(hash !== undefined ? {hash} : {})};
  }
  if (!winner) return {reason:"noCandidates"};
  return {cardID:winner.entry.card.id,reason:coverage ? "coverage" : winner.boosted ? "preferred" : winner.never ? "firstReturn" : "longWait",waitingDays:winner.wait,automaticOrdinal:ordinal};
}
