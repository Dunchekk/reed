import type {ProjectedLibrary} from "./projection.ts";
import type {ReturnDecision,ReturnSlot} from "./models.ts";
import {ReturnScheduleError} from "./models.ts";
import {ZonedCalendar} from "./calendar.ts";
import {planSlots} from "./slots.ts";
import {PreparedCandidates,selectReturn} from "./selector.ts";
export interface PlannedSlot {slot:ReturnSlot;decision:ReturnDecision}
export function planReturns(library:ProjectedLibrary,now:number,calendar:ZonedCalendar,seeds:Map<string,bigint>):PlannedSlot[] {
  const {settings,candidates,historyEnabled,past}=library,prepared=new PreparedCandidates(candidates,settings);
  const individual=library.individual.filter(rule=>prepared.explicit.has(rule.cardID));
  const occupied=past.filter(item=>item.decision.cardID),start=calendar.components(now),interval=settings.minimumIntervalMinutes*60000;
  let slots:ReturnSlot[]=[];
  for(let offset=0;offset<8;offset++){
    const day=calendar.addingDays(start,offset),key=calendar.key(day);
    const generated=planSlots(day,seeds.get(key)!,settings,individual,calendar).filter(slot=>slot.date>now);
    const remaining=Math.max(0,settings.dailyLimit-occupied.filter(item=>calendar.dayKey(item.slot.date)===key).length);
    const explicit=generated.filter(slot=>slot.explicitCardID);
    if(explicit.length>remaining)throw new ReturnScheduleError("tooManyExplicitTimes");
    slots.push(...explicit,...generated.filter(slot=>!slot.explicitCardID).slice(0,remaining-explicit.length));
  }
  slots.sort((a,b)=>a.date-b.date || a.id.localeCompare(b.id));
  const appointments=slots.filter(slot=>slot.explicitCardID);
  let previousExplicit:number|undefined;
  for(const slot of appointments){
    if((previousExplicit!==undefined && slot.date-previousExplicit<interval) || occupied.some(item=>Math.abs(item.slot.date-slot.date)<interval))throw new ReturnScheduleError("conflictingExplicitTimes");
    previousExplicit=slot.date;
  }
  const horizon=calendar.date(calendar.addingDays(start,7),0)!;
  slots=slots.filter(slot=>slot.date<horizon && (slot.explicitCardID || !appointments.some(item=>Math.abs(item.date-slot.date)<interval))).slice(0,48);
  const reservations=occupied.map(item=>({cardID:item.decision.cardID!,date:item.slot.date}));
  reservations.push(...slots.filter(slot=>slot.explicitCardID).map(slot=>({cardID:slot.explicitCardID!,date:slot.date})));
  let ordinal=occupied.reduce((value,item)=>Math.max(value,item.decision.automaticOrdinal??0),0);
  let previousTime=occupied.reduce((value,item)=>Math.max(value,item.slot.date),-Infinity);
  const sourceByCard=new Map(candidates.map(card=>[card.id,card.sourceID])),usedByDay=new Map<string,Set<string>>();
  const addSource=(id:string,date:number)=>{const source=sourceByCard.get(id);if(source){const key=calendar.dayKey(date);if(!usedByDay.has(key))usedByDay.set(key,new Set());usedByDay.get(key)!.add(source);}};
  for(const event of reservations)if(event.date<=now)addSource(event.cardID,event.date);
  const result:PlannedSlot[]=[];
  for(const slot of slots){
    if(slot.date-previousTime<interval)continue;
    const decision=selectReturn(slot,prepared,settings,reservations,ordinal,historyEnabled,usedByDay.get(calendar.dayKey(slot.date)));
    if(decision.cardID){reservations.push({cardID:decision.cardID,date:slot.date});ordinal=decision.automaticOrdinal??ordinal;previousTime=slot.date;addSource(decision.cardID,slot.date);}
    result.push({slot,decision});
  }
  return result;
}
