import {isDeepStrictEqual} from "node:util";
import {randomBytes,randomUUID} from "node:crypto";
import type {PoolClient} from "pg";
import {CloudDatabase} from "../cloud/database.ts";
import type {LibraryState} from "../cloud/database.ts";
import type {CloudScope} from "../cloud/contracts.ts";
import {ZonedCalendar} from "./calendar.ts";
import {projectLibrary} from "./projection.ts";
import {planReturns} from "./planner.ts";
import {ReturnScheduleError} from "./models.ts";
import type {ReturnDecision,ReturnSlot} from "./models.ts";
export interface CloudPlan {epoch:string;sequence:number;timeZone:string;issue?:string;entries:Array<{slot:Omit<ReturnSlot,"date">&{date:string};decision:ReturnDecision;revision:string}>}
export class CloudReturns {
  readonly database:CloudDatabase;readonly now:()=>number;
  constructor(database:CloudDatabase,now:()=>number=Date.now){this.database=database;this.now=now;}
  async plan(scope:CloudScope,epoch:string):Promise<CloudPlan>{return this.database.device(scope,epoch,(client,state)=>this.prepare(client,scope.accountID,state));}
  async refresh(accountID:string):Promise<void>{await this.database.account(accountID,(client,state)=>this.prepare(client,accountID,state));}
  async prepare(client:PoolClient,accountID:string,state:LibraryState):Promise<CloudPlan>{
    const now=this.now(),primary=(await client.query("SELECT time_zone FROM cloud_devices WHERE account_id=$1 AND is_primary AND revoked_at IS NULL",[accountID])).rows[0];
    const timeZone=primary?.time_zone??"UTC",calendar=new ZonedCalendar(timeZone),day=calendar.components(now),key=calendar.key(day);
    let saved=(await client.query("SELECT * FROM cloud_return_plans WHERE account_id=$1",[accountID])).rows[0];
    if(!saved || Number(saved.sequence)!==state.sequence || saved.day_key!==key){
      let issue:string|undefined,planned:ReturnType<typeof planReturns>=[];
      try{
        const rows=(await client.query("SELECT kind,id,payload FROM cloud_records WHERE account_id=$1 AND payload IS NOT NULL",[accountID])).rows;
        const library=projectLibrary(rows,now,calendar);
        const past=(await client.query("SELECT slot,decision FROM cloud_return_slots WHERE account_id=$1 AND NOT cancelled AND scheduled_at<=$2",[accountID,new Date(now)])).rows;
        const merged=new Map(library.past.map(item=>[item.slot.id,item]));
        for(const item of past)merged.set(item.slot.id,{slot:{...item.slot,date:Date.parse(item.slot.date)},decision:item.decision});
        library.past=[...merged.values()];
        const seeds=new Map<string,bigint>();
        for(let offset=0;offset<8;offset++){
          const dayKey=calendar.key(calendar.addingDays(day,offset));
          await client.query("INSERT INTO cloud_return_days VALUES($1,$2,$3) ON CONFLICT DO NOTHING",[accountID,dayKey,randomBytes(8).readBigUInt64BE().toString()]);
          seeds.set(dayKey,BigInt((await client.query("SELECT seed FROM cloud_return_days WHERE account_id=$1 AND day_key=$2",[accountID,dayKey])).rows[0].seed));
        }
        if(primary)planned=planReturns(library,now,calendar,seeds);else issue="noPrimaryDevice";
      }catch(error){if(error instanceof ReturnScheduleError)issue=error.code;else throw error;}
      const existing=(await client.query("SELECT id,slot,decision,revision FROM cloud_return_slots WHERE account_id=$1 AND NOT cancelled AND scheduled_at>$2",[accountID,new Date(now)])).rows;
      const previous=new Map(existing.map(row=>[row.id,row]));
      await client.query("UPDATE cloud_return_slots SET cancelled=true WHERE account_id=$1 AND scheduled_at>$2",[accountID,new Date(now)]);
      for(const item of planned){
        const slot={...item.slot,date:new Date(item.slot.date).toISOString()},old=previous.get(slot.id);
        const equal=old && isDeepStrictEqual(old.slot,slot) && isDeepStrictEqual(old.decision,item.decision);
        await client.query(`INSERT INTO cloud_return_slots VALUES($1,$2,$3,$4,$5,$6,false) ON CONFLICT(account_id,id) DO UPDATE SET
          scheduled_at=EXCLUDED.scheduled_at,slot=EXCLUDED.slot,decision=EXCLUDED.decision,revision=EXCLUDED.revision,cancelled=false`,[accountID,slot.id,new Date(item.slot.date),slot,item.decision,equal?old.revision:randomUUID()]);
      }
      await client.query(`INSERT INTO cloud_return_plans VALUES($1,$2,$3,$4,$5) ON CONFLICT(account_id) DO UPDATE SET
        sequence=EXCLUDED.sequence,day_key=EXCLUDED.day_key,time_zone=EXCLUDED.time_zone,issue=EXCLUDED.issue`,[accountID,state.sequence,key,timeZone,issue??null]);
      saved={issue};
    }
    const entries=(await client.query("SELECT slot,decision,revision FROM cloud_return_slots WHERE account_id=$1 AND NOT cancelled AND scheduled_at>=$2 ORDER BY scheduled_at,id",[accountID,new Date(calendar.date(day,0)!)])).rows;
    return {epoch:state.epoch,sequence:state.sequence,timeZone,...(saved.issue?{issue:saved.issue}:{}),entries};
  }
}
