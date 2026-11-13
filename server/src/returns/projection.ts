import type {Payload,RecordKind} from "../cloud/contracts.ts";
import type {ReturnCandidate,ReturnSettings,CardReturnSettings,WordRule,ReturnDecision,ReturnSlot} from "./models.ts";
import {defaultSettings,ReturnScheduleError} from "./models.ts";
import {tokens} from "./policy.ts";
import {ZonedCalendar} from "./calendar.ts";
interface Card {id:string;text:string;title:string;comment:string;sourceID?:string;folderID?:string;tagIDs:string[];createdAt:string;isFavorite:boolean;isHidden:boolean;deletedAt?:string;allowsReturns:boolean}
interface Source {title:string;authorIDs:string[]}
export interface ProjectedLibrary {settings:ReturnSettings;candidates:ReturnCandidate[];individual:CardReturnSettings[];historyEnabled:boolean;past:Array<{slot:ReturnSlot;decision:ReturnDecision}>}
/** Only validated records enter here; dangling tombstone references never broaden filters. */
export function projectLibrary(rows:Array<{kind:RecordKind;id:string;payload:Payload}>,now:number,calendar:ZonedCalendar):ProjectedLibrary {
  const byKind = new Map<RecordKind,Map<string,Record<string,unknown>>>();
  for(const row of rows) if(row.payload){if(!byKind.has(row.kind))byKind.set(row.kind,new Map());byKind.get(row.kind)!.set(row.id,row.payload);}
  const records = <T>(kind:RecordKind) => (byKind.get(kind) ?? new Map()) as Map<string,T>;
  const settings = records<ReturnSettings>("returnSettings").get("global") ?? defaultSettings();
  const historyEnabled = records<{enabled:boolean}>("historyPreference").get("global")?.enabled ?? true;
  const authors=records<{name:string}>("author"),sources=records<Source>("source"),folders=records<unknown>("folder"),tags=records<unknown>("tag");
  const rules = [...records<CardReturnSettings>("cardReturn").values()], ruleByCard = new Map(rules.map(rule => [rule.cardID,rule]));
  const filters = (["globalInclude","globalExclude","channelInclude","channelExclude"] as WordRule[]).map(key => ({key,filter:settings[key],words:tokens(settings[key].words)}));
  for(const {filter} of filters) if(filter.tags.some(id=>!tags.has(id)) || filter.folders.some(id=>!folders.has(id)) || filter.authors.some(id=>!authors.has(id))) throw new ReturnScheduleError("invalidFilter");
  const openings = new Map<string,{last:number;days:Set<string>}>();
  if(historyEnabled) for(const opening of records<{cardID:string;date:string;origin:string}>("opening").values()) {
    const date=Date.parse(opening.date);if(opening.origin!=="manual" || date<now-90*86400000 || date>now)continue;
    const value=openings.get(opening.cardID)??{last:date,days:new Set<string>()};value.last=Math.max(value.last,date);value.days.add(calendar.dayKey(date));openings.set(opening.cardID,value);
  }
  const candidates=[...records<Card>("card").values()].map(card=>{
    const source=card.sourceID ? sources.get(card.sourceID):undefined,rule=ruleByCard.get(card.id),opening=openings.get(card.id);
    const authorIDs=source?.authorIDs.filter(id=>authors.has(id))??[];
    const words=tokens([card.text,card.title,card.comment,source?.title??"",...authorIDs.map(id=>authors.get(id)!.name)].join(" "));
    const wordMatches=new Set(filters.filter(({words:query,filter})=>query.length && (filter.wordMode==="all" ? query.every(q=>words.some(word=>word.startsWith(q))) : query.some(q=>words.some(word=>word.startsWith(q))))).map(item=>item.key));
    return {id:card.id,createdAt:Date.parse(card.createdAt),...(source ? {sourceID:card.sourceID}:{}),...(card.folderID && folders.has(card.folderID)?{folderID:card.folderID}:{}),
      tags:new Set(card.tagIDs.filter(id=>tags.has(id))),authors:new Set(authorIDs),isFavorite:card.isFavorite,isHidden:card.isHidden,isDeleted:!!card.deletedAt,allowsReturns:card.allowsReturns,
      notificationsEnabled:rule?.notificationsEnabled ?? true,wordMatches,manualOpeningDays:opening?.days.size??0,...(opening?{lastManualOpening:opening.last}:{}),...(rule?.deferredUntil?{deferredUntil:Date.parse(rule.deferredUntil)}:{})};
  });
  const past=[...records<{slot:Omit<ReturnSlot,"date">&{date:string};decision:ReturnDecision}>("returnHistory").values()].map(value=>({...value,slot:{...value.slot,date:Date.parse(value.slot.date)}})).filter(value=>value.slot.date<=now);
  return {settings,candidates,individual:rules,historyEnabled,past};
}
