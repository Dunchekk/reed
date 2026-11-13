import {randomUUID} from "node:crypto";
import {CloudDatabase} from "../cloud/database.ts";
import {CloudReturns} from "../returns/service.ts";
import {projectLibrary} from "../returns/projection.ts";
import {ZonedCalendar} from "../returns/calendar.ts";
import {admission} from "../returns/policy.ts";
import type {PushProvider} from "./provider.ts";
/** A durable claim precedes network IO. Ambiguous sends are never automatically repeated. */
export class CloudPushWorker {
  private running:Promise<void>|undefined;readonly database:CloudDatabase;readonly returns:CloudReturns;readonly provider:PushProvider|undefined;readonly now:()=>number;
  constructor(database:CloudDatabase,returns:CloudReturns,provider?:PushProvider,now:()=>number=Date.now){this.database=database;this.returns=returns;this.provider=provider;this.now=now;}
  run():Promise<void>{if(this.running)return this.running;this.running=this.process().finally(()=>{this.running=undefined;});return this.running;}
  private async process():Promise<void>{
    const accounts=(await this.database.pool.query("SELECT l.account_id FROM cloud_libraries l JOIN accounts a ON a.id=l.account_id WHERE a.deletion_status='active' ORDER BY l.account_id")).rows;
    let failed=false;
    for(const {account_id:accountID} of accounts){try{await this.refreshAccount(accountID);}catch{failed=true;}}
    if(failed)throw new Error("Cloud returns will retry");
  }
  async refreshAccount(accountID:string):Promise<void>{await this.returns.refresh(accountID);if(this.provider)await this.deliverAccount(accountID);}
  private async deliverAccount(accountID:string):Promise<void>{
    const now=this.now();
    await this.database.pool.query("UPDATE cloud_push_outbox SET state='unknown' WHERE account_id=$1 AND state='sending' AND updated_at<$2",[accountID,new Date(now-60_000)]);
    const due=(await this.database.pool.query(`SELECT s.id FROM cloud_return_slots s LEFT JOIN cloud_push_outbox o ON o.account_id=s.account_id AND o.slot_id=s.id
      WHERE s.account_id=$1 AND NOT s.cancelled AND s.scheduled_at<=$2 AND s.scheduled_at>$3 AND s.decision->>'cardID' IS NOT NULL
      AND (o.slot_id IS NULL OR (o.state='retry' AND o.retry_at<=$2)) ORDER BY s.scheduled_at LIMIT 10`,[accountID,new Date(now),new Date(now-15*60_000)])).rows;
    for(const {id:slotID} of due){
      const attempt=randomUUID();
      const claimed=await this.database.account(accountID,async client=>{
        const receiver=(await client.query("SELECT id FROM cloud_devices WHERE account_id=$1 AND is_primary AND is_ready AND NOT suspended AND revoked_at IS NULL AND push_token IS NOT NULL",[accountID])).rows[0];
        if(!receiver)return false;
        const result=await client.query(`INSERT INTO cloud_push_outbox(account_id,slot_id,attempt_id,device_id,state) VALUES($1,$2,$3,$4,'sending')
          ON CONFLICT(account_id,slot_id) DO UPDATE SET attempt_id=EXCLUDED.attempt_id,device_id=EXCLUDED.device_id,state='sending',updated_at=now(),retry_at=NULL
          WHERE cloud_push_outbox.state='retry' AND cloud_push_outbox.retry_at<=$5 RETURNING slot_id`,[accountID,slotID,attempt,receiver.id,new Date(now)]);
        return !!result.rowCount;
      });
      if(!claimed)continue;
      await this.database.account(accountID,async(client,state)=>{
        // Hold the account lock through the bounded send so revocation and primary switches cannot interleave.
        const job=(await client.query("SELECT * FROM cloud_push_outbox WHERE account_id=$1 AND slot_id=$2 AND attempt_id=$3 AND state='sending'",[accountID,slotID,attempt])).rows[0];if(!job)return;
        const device=(await client.query("SELECT * FROM cloud_devices WHERE account_id=$1 AND id=$2 AND is_primary AND is_ready AND NOT suspended AND revoked_at IS NULL AND push_token IS NOT NULL",[accountID,job.device_id])).rows[0];
        const slot=(await client.query("SELECT * FROM cloud_return_slots WHERE account_id=$1 AND id=$2 AND NOT cancelled",[accountID,slotID])).rows[0];
        let allowed=false;
        if(device && slot){
          try{
            const plan=await this.returns.prepare(client,accountID,state);
            const library=projectLibrary((await client.query("SELECT kind,id,payload FROM cloud_records WHERE account_id=$1 AND payload IS NOT NULL",[accountID])).rows,now,new ZonedCalendar(device.time_zone));
            const candidate=library.candidates.find(card=>card.id===slot.decision.cardID);
            allowed=!plan.issue && !!candidate && admission(library.settings)(candidate,!!slot.slot.explicitCardID);
          }catch{allowed=false;}
        }
        let outcome:Awaited<ReturnType<PushProvider["send"]>>|"skipped"="skipped";
        if(allowed){try{outcome=await this.provider!.send({id:attempt,token:device.push_token,accountID,cardID:slot.decision.cardID,slotID,expiresAt:now+15*60_000});}catch{outcome="unknown";}}
        if(outcome==="invalidToken")await client.query("UPDATE cloud_devices SET push_token=NULL WHERE account_id=$1 AND id=$2 AND push_token=$3",[accountID,device.id,device.push_token]);
        await client.query("UPDATE cloud_push_outbox SET state=$4,updated_at=now(),retry_at=$5 WHERE account_id=$1 AND slot_id=$2 AND attempt_id=$3",[accountID,slotID,attempt,outcome==="invalidToken"?"rejected":outcome,outcome==="retry"?new Date(now+60_000):null]);
      });
    }
  }
}
