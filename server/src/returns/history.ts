import type {ReturnDecision,ReturnSlot} from "./models.ts";
export interface WireReturn {slot:Omit<ReturnSlot,"date"> & {date:string};decision:ReturnDecision;revision:string}
/** Sufficient state for the selector: latest return per card, recent local-day quota, and global ordinal. */
export function compactHistory(history:WireReturn[],now:number):WireReturn[]{
  const latest=new Map<string,WireReturn>(),selected=new Map<string,WireReturn>();
  let highest:WireReturn|undefined;
  for(const entry of history){
    const id=entry.decision.cardID,date=Date.parse(entry.slot.date);
    if(!id || date>now)continue;
    const previous=latest.get(id);
    if(!previous || date>Date.parse(previous.slot.date))latest.set(id,entry);
    if(date>=now-48*3600000)selected.set(entry.slot.id,entry);
    if((entry.decision.automaticOrdinal??0)>(highest?.decision.automaticOrdinal??0))highest=entry;
  }
  for(const entry of latest.values())selected.set(entry.slot.id,entry);
  if(highest)selected.set(highest.slot.id,highest);
  return [...selected.values()].sort((a,b)=>Date.parse(a.slot.date)-Date.parse(b.slot.date) || a.slot.id.localeCompare(b.slot.id));
}
