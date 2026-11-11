import {randomUUID} from "node:crypto";
import type {Pool,PoolClient} from "pg";
import {AuthError} from "../auth/provider.ts";
import {CloudError} from "./contracts.ts";
import type {CloudScope} from "./contracts.ts";

export interface LibraryState {epoch:string; sequence:number}
/** Account lock is always acquired first; sequences cannot commit out of order. */
export class CloudDatabase {
  readonly pool:Pool;
  constructor(pool:Pool){this.pool=pool;}
  async account<T>(accountID:string,work:(client:PoolClient,state:LibraryState)=>Promise<T>):Promise<T>{
    const client=await this.pool.connect();
    try{
      await client.query("BEGIN");
      const account=await client.query("SELECT id FROM accounts WHERE id=$1 AND deletion_status='active' FOR UPDATE",[accountID]);
      if(!account.rowCount)throw new AuthError("unauthorized");
      await client.query("INSERT INTO cloud_libraries(account_id,epoch) VALUES($1,$2) ON CONFLICT DO NOTHING",[accountID,randomUUID()]);
      const row=(await client.query<{epoch:string;sequence:string}>("SELECT epoch,sequence FROM cloud_libraries WHERE account_id=$1 FOR UPDATE",[accountID])).rows[0]!;
      const result=await work(client,{epoch:row.epoch,sequence:Number(row.sequence)});
      await client.query("COMMIT");return result;
    }catch(error){await client.query("ROLLBACK");throw error;}finally{client.release();}
  }
  async device<T>(scope:CloudScope,epoch:string,work:(client:PoolClient,state:LibraryState)=>Promise<T>):Promise<T>{
    return this.account(scope.accountID,async(client,state)=>{
      if(state.epoch!==epoch.toLowerCase())throw new CloudError("epoch_changed");
      if(!(await client.query("SELECT id FROM cloud_devices WHERE account_id=$1 AND id=$2 AND revoked_at IS NULL",[scope.accountID,scope.deviceID])).rowCount)throw new CloudError("device_revoked");
      return work(client,state);
    });
  }
}
