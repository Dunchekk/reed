import type {PoolClient} from "pg";

/** Privacy erasure is the sole exception to the immutable payload journal; cursors stay contiguous. */
export async function eraseOpeningPayloads(client:PoolClient,accountID:string,ids:string[]):Promise<void>{
  if(!ids.length)return;
  await client.query("UPDATE cloud_changes SET payload=NULL WHERE account_id=$1 AND kind='opening' AND id=ANY($2::text[])",[accountID,ids]);
  await client.query(`UPDATE cloud_operations SET result=jsonb_set(result,'{record,payload}','null'::jsonb)
    WHERE account_id=$1 AND result->'record'->>'kind'='opening' AND result->'record'->>'id'=ANY($2::text[])`,[accountID,ids]);
}
