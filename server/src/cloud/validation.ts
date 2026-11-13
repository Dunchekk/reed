import {tokens} from "../returns/policy.ts";
import {CloudError,recordKinds} from "./contracts.ts";
import type {Mutation,Payload,RecordKind,MediaManifest} from "./contracts.ts";

export function object(value: unknown): Record<string,unknown> {
  if (!value || typeof value!=="object" || Array.isArray(value)) throw new CloudError("invalid_record");
  return value as Record<string,unknown>;
}
export function string(value: unknown, maximum: number, nonempty=true): string {
  if(typeof value!=="string" || Buffer.byteLength(value)>maximum || (nonempty&&!value.trim())) throw new CloudError("invalid_record");
  return value;
}
export function integer(value: unknown, minimum=0, maximum=Number.MAX_SAFE_INTEGER): number {
  if(typeof value!=="number" || !Number.isSafeInteger(value) || value<minimum || value>maximum) throw new CloudError("invalid_record");
  return value;
}
export function uuid(value: unknown): string {
  const id=string(value,36);
  if(!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id)) throw new CloudError("invalid_record");
  return id.toLowerCase();
}
function boolean(value: unknown): boolean { if(typeof value!=="boolean") throw new CloudError("invalid_record");return value; }
function date(value: unknown): string {
  const raw=string(value,40), timestamp=Date.parse(raw);
  if(!Number.isFinite(timestamp) || Math.abs(timestamp)>=253402300800000 || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,3})?Z$/.test(raw) || new Date(timestamp).toISOString().slice(0,19)!==raw.slice(0,19)) throw new CloudError("invalid_record");
  return new Date(timestamp).toISOString();
}
function keys(value: Record<string,unknown>, allowed: string[]) {
  if(Object.keys(value).some(key=>!allowed.includes(key))) throw new CloudError("invalid_record");
}
function ids(value: unknown, maximum=100): string[] {
  if(!Array.isArray(value) || value.length>maximum) throw new CloudError("invalid_record");
  const result=value.map(uuid);if(new Set(result).size!==result.length)throw new CloudError("invalid_record");return result;
}
function numbers(value: unknown, maximum:number, min:number,max:number): number[] {
  if(!Array.isArray(value)||value.length>maximum)throw new CloudError("invalid_record");
  const result=value.map(v=>integer(v,min,max));if(new Set(result).size!==result.length)throw new CloudError("invalid_record");return result;
}
function optional(output: Record<string,unknown>, input:Record<string,unknown>, key:string, validate:(v:unknown)=>unknown) {
  if(input[key]!==undefined&&input[key]!==null)output[key]=validate(input[key]);
}
function filter(raw:unknown):Record<string,unknown> {
  const input=object(raw);keys(input,["tags","folders","authors","words","tagMode","authorMode","wordMode","createdAfter","createdBefore"]);
  const result:Record<string,unknown>={tags:ids(input.tags),folders:ids(input.folders),authors:ids(input.authors),words:string(input.words,8192,false)};
  if(tokens(String(result.words)).length>64)throw new CloudError("invalid_record");
  for(const key of ["tagMode","authorMode","wordMode"]) {if(input[key]!=="any"&&input[key]!=="all")throw new CloudError("invalid_record");result[key]=input[key];}
  optional(result,input,"createdAfter",date);optional(result,input,"createdBefore",date);
  if(result.createdAfter&&result.createdBefore&&String(result.createdAfter)>=String(result.createdBefore))throw new CloudError("invalid_record");return result;
}
export function validatePayload(kind:RecordKind,id:string,raw:unknown):Payload {
  if(raw===null)return null;
  const input=object(raw), result:Record<string,unknown>={};
  if(["card","source","author","tag","folder","opening"].includes(kind)) {if(uuid(input.id)!==id)throw new CloudError("invalid_record");result.id=id;}
  switch(kind) {
    case "author":case "tag":case "folder": keys(input,["id","name"]);result.name=string(input.name,1200);break;
    case "source":
      keys(input,["id","title","authorIDs","url"]);result.title=string(input.title,1200);result.authorIDs=ids(input.authorIDs);
      optional(result,input,"url",v=>string(v,8192,false));break;
    case "card":
      keys(input,["id","text","title","comment","page","sourceID","folderID","tagIDs","attachmentIDs","createdAt","updatedAt","isFavorite","isHidden","allowsReturns","deletedAt"]);
      result.text=string(input.text,2_000_000);result.title=string(input.title,4096,false);result.comment=string(input.comment,500_000,false);result.page=string(input.page,4096,false);
      optional(result,input,"sourceID",uuid);optional(result,input,"folderID",uuid);result.tagIDs=ids(input.tagIDs);result.attachmentIDs=ids(input.attachmentIDs);
      result.createdAt=date(input.createdAt);result.updatedAt=date(input.updatedAt);optional(result,input,"deletedAt",date);
      for(const key of ["isFavorite","isHidden","allowsReturns"])result[key]=boolean(input[key]);break;
    case "returnSettings":
      keys(input,["enabled","notificationsEnabled","dailyLimit","weekdays","firstMinute","lastMinute","minimumIntervalMinutes","jitterMinutes","globalInclude","globalExclude","channelInclude","channelExclude","boostEnabled","boostFolderID"]);
      for(const key of ["enabled","notificationsEnabled","boostEnabled"])result[key]=boolean(input[key]);
      result.dailyLimit=integer(input.dailyLimit,1,10);result.weekdays=numbers(input.weekdays,7,1,7);
      result.firstMinute=integer(input.firstMinute,0,1439);result.lastMinute=integer(input.lastMinute,0,1439);
      result.minimumIntervalMinutes=integer(input.minimumIntervalMinutes,60,720);result.jitterMinutes=integer(input.jitterMinutes,0,60);
      if(Number(result.firstMinute)>Number(result.lastMinute)||(Number(result.dailyLimit)-1)*Number(result.minimumIntervalMinutes)>Number(result.lastMinute)-Number(result.firstMinute))throw new CloudError("invalid_record");
      for(const key of ["globalInclude","globalExclude","channelInclude","channelExclude"])result[key]=filter(input[key]);
      optional(result,input,"boostFolderID",uuid);break;
    case "cardReturn":
      keys(input,["cardID","notificationsEnabled","minutes","weekdays","deferredUntil"]);
      if(uuid(input.cardID)!==id)throw new CloudError("invalid_record");result.cardID=id;
      result.notificationsEnabled=boolean(input.notificationsEnabled);result.minutes=numbers(input.minutes,10,0,1439);result.weekdays=numbers(input.weekdays,7,1,7);optional(result,input,"deferredUntil",date);break;
    case "opening":
      keys(input,["id","cardID","date","origin"]);result.cardID=uuid(input.cardID);result.date=date(input.date);
      if(input.origin!=="manual"&&input.origin!=="notification")throw new CloudError("invalid_record");result.origin=input.origin;break;
    case "historyPreference": keys(input,["enabled"]);result.enabled=boolean(input.enabled);break;
    case "returnHistory": {
      keys(input,["slot","decision"]);const slot=object(input.slot),decision=object(input.decision);
      keys(slot,["id","date","explicitCardID"]);keys(decision,["cardID","reason","waitingDays","automaticOrdinal"]);
      const normalizedSlot:Record<string,unknown>={id:string(slot.id,300),date:date(slot.date)};optional(normalizedSlot,slot,"explicitCardID",uuid);
      if(Date.parse(String(normalizedSlot.date))>Date.now()+60_000)throw new CloudError("invalid_record");
      if(!["firstReturn","longWait","preferred","coverage","explicit","noCandidates"].includes(String(decision.reason)))throw new CloudError("invalid_record");
      const normalizedDecision:Record<string,unknown>={reason:decision.reason};optional(normalizedDecision,decision,"cardID",uuid);
      optional(normalizedDecision,decision,"automaticOrdinal",v=>integer(v,1,1_000_000_000));
      optional(normalizedDecision,decision,"waitingDays",v=>{if(typeof v!=="number"||!Number.isFinite(v)||v<0||v>4_000_000)throw new CloudError("invalid_record");return v;});
      result.slot=normalizedSlot;result.decision=normalizedDecision;break;
    }
  }
  return result;
}
export function validateMutation(raw:unknown):Mutation {
  const input=object(raw);keys(input,["operationID","kind","id","baseVersion","payload"]);
  if(!recordKinds.includes(input.kind as RecordKind))throw new CloudError("invalid_record");
  const kind=input.kind as RecordKind;
  const id=kind==="returnSettings"||kind==="historyPreference"?string(input.id,6):uuid(input.id);
  if((kind==="returnSettings"||kind==="historyPreference")&&id!=="global")throw new CloudError("invalid_record");
  return {operationID:uuid(input.operationID),kind,id,baseVersion:integer(input.baseVersion),payload:validatePayload(kind,id,input.payload)};
}
export function validateManifest(raw:unknown):MediaManifest {
  const value=object(raw);keys(value,["id","original","thumbnail"]);
  const part=(raw:unknown,maximum:number)=>{const input=object(raw);keys(input,["size","sha256"]);const hash=string(input.sha256,64);if(!/^[a-f0-9]{64}$/.test(hash))throw new CloudError("corrupted_media");return {size:integer(input.size,1,maximum),sha256:hash};};
  return {id:uuid(value.id),original:part(value.original,40*1024*1024),thumbnail:part(value.thumbnail,10*1024*1024)};
}
