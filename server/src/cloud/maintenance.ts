import {eraseOpeningPayloads} from "./privacy.ts";
import {CloudDatabase} from "./database.ts";
import {appendRecord} from "./records.ts";
import type {ObjectStore} from "./media/object-store.ts";

export class CloudMaintenance {
  readonly database:CloudDatabase;readonly objects:ObjectStore;private running:Promise<void>|undefined;
  constructor(database:CloudDatabase,objects:ObjectStore){this.database=database;this.objects=objects;}
  run():Promise<void>{if(this.running)return this.running;this.running=this.process().finally(()=>{this.running=undefined;});return this.running;}
  private async process():Promise<void>{
    const accounts=(await this.database.pool.query("SELECT l.account_id FROM cloud_libraries l JOIN accounts a ON a.id=l.account_id WHERE a.deletion_status='active'")).rows;
    for(const row of accounts)await this.account(row.account_id);
    for(const row of (await this.database.pool.query("SELECT account_id,epoch FROM cloud_object_cleanup")).rows){
      await this.objects.removeEpoch({accountID:row.account_id,epoch:row.epoch});
      await this.database.pool.query("DELETE FROM cloud_object_cleanup WHERE account_id=$1 AND epoch=$2",[row.account_id,row.epoch]);
    }
  }
  async account(accountID:string):Promise<void>{
    await this.database.account(accountID,async(client,state)=>{
      const old=(await client.query("SELECT id,version FROM cloud_records WHERE account_id=$1 AND kind='opening' AND payload IS NOT NULL AND (payload->>'date')::timestamptz<now()-interval '90 days'",[accountID])).rows;
      for(const row of old)await appendRecord(client,accountID,state,"opening",row.id,Number(row.version)+1,null);
      await eraseOpeningPayloads(client,accountID,old.map(row=>row.id));
      await client.query("UPDATE cloud_changes SET payload=NULL WHERE account_id=$1 AND kind='opening' AND payload IS NOT NULL AND (payload->>'date')::timestamptz<now()-interval '90 days'",[accountID]);
      await client.query(`UPDATE cloud_operations SET result=jsonb_set(result,'{record,payload}','null'::jsonb)
        WHERE account_id=$1 AND result->'record'->>'kind'='opening' AND (result->'record'->'payload'->>'date')::timestamptz<now()-interval '90 days'`,[accountID]);
      const scope={accountID,epoch:state.epoch};
      // These rows were committed by an earlier pass. Re-uploaded media cancels deletion.
      for(const row of (await client.query("SELECT epoch,id FROM cloud_media_cleanup WHERE account_id=$1",[accountID])).rows){
        const retained=await client.query("SELECT id FROM cloud_media WHERE account_id=$1 AND id=$2 UNION ALL SELECT attachment_id FROM cloud_uploads WHERE account_id=$1 AND attachment_id=$2",[accountID,row.id]);
        if(!retained.rowCount)await this.objects.removeMedia({accountID,epoch:row.epoch},row.id);
        await client.query("DELETE FROM cloud_media_cleanup WHERE account_id=$1 AND epoch=$2 AND id=$3",[accountID,row.epoch,row.id]);
      }
      const expiredUploads=(await client.query("SELECT id,attachment_id FROM cloud_uploads WHERE account_id=$1 AND expires_at<now()",[accountID])).rows;
      for(const row of expiredUploads){await client.query("DELETE FROM cloud_uploads WHERE account_id=$1 AND id=$2",[accountID,row.id]);}
      await client.query(`UPDATE cloud_media m SET unreferenced_since=CASE WHEN EXISTS(
        SELECT 1 FROM cloud_records r WHERE r.account_id=m.account_id AND r.kind='card' AND r.payload->'attachmentIDs' ? m.id::text
      ) THEN NULL ELSE COALESCE(unreferenced_since,now()) END WHERE account_id=$1`,[accountID]);
      const unused=(await client.query(`SELECT m.id FROM cloud_media m WHERE m.account_id=$1 AND m.unreferenced_since<now()-interval '7 days'
        AND NOT EXISTS(SELECT 1 FROM cloud_uploads u WHERE u.account_id=m.account_id AND u.attachment_id=m.id AND u.expires_at>now())`,[accountID])).rows;
      for(const row of unused){
        await client.query("INSERT INTO cloud_media_cleanup VALUES($1,$2,$3) ON CONFLICT DO NOTHING",[accountID,state.epoch,row.id]);
        await client.query("DELETE FROM cloud_media WHERE account_id=$1 AND id=$2",[accountID,row.id]);
      }
      const uploads=(await client.query("SELECT id,attachment_id FROM cloud_uploads WHERE account_id=$1",[accountID])).rows;
      const media=(await client.query("SELECT id FROM cloud_media WHERE account_id=$1",[accountID])).rows;
      await this.objects.removeOrphans(scope,new Set([...uploads,...expiredUploads].map(row=>row.id)),new Set([...media.map(row=>row.id),...uploads.map(row=>row.attachment_id),...unused.map(row=>row.id),...expiredUploads.map(row=>row.attachment_id)]),new Date(Date.now()-7*86400000));
    });
  }
  /** Called only after deletion_status is pending; all cloud endpoints already reject this account. */
  async deleteAccount(accountID:string):Promise<void>{
    const client=await this.database.pool.connect();
    try{
      await client.query("BEGIN");
      const pending=await client.query("SELECT id FROM accounts WHERE id=$1 AND deletion_status='pending' FOR UPDATE",[accountID]);
      if(pending.rowCount){
        await this.objects.removeAccount(accountID);
        await client.query("DELETE FROM cloud_libraries WHERE account_id=$1",[accountID]);
        await client.query("DELETE FROM cloud_object_cleanup WHERE account_id=$1",[accountID]);
      }
      await client.query("COMMIT");
    }catch(error){await client.query("ROLLBACK");throw error;}finally{client.release();}
  }
}
