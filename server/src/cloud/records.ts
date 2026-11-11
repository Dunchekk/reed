import {createHash} from "node:crypto";
import type {PoolClient} from "pg";
import {CloudDatabase} from "./database.ts";
import type {LibraryState} from "./database.ts";
import {CloudError} from "./contracts.ts";
import type {CloudScope,CloudRecord,Mutation,MutationResult,Payload,RecordKind} from "./contracts.ts";
import {validateMutation} from "./validation.ts";

export function canonical(value:unknown):string {
  if(value===null||typeof value!=="object")return JSON.stringify(value);
  if(Array.isArray(value))return `[${value.map(canonical).join(",")}]`;
  return `{${Object.entries(value).sort(([a],[b])=>a.localeCompare(b,"en")).map(([key,v])=>`${JSON.stringify(key)}:${canonical(v)}`).join(",")}}`;
}
export function record(row:{kind:RecordKind;id:string;version:string|number;sequence:string|number;payload:Payload}):CloudRecord {
  return {...row,version:Number(row.version),sequence:Number(row.sequence)};
}
export async function appendRecord(client:PoolClient,accountID:string,state:LibraryState,kind:RecordKind,id:string,version:number,payload:Payload):Promise<CloudRecord>{
  if(state.sequence>=Number.MAX_SAFE_INTEGER||version>=Number.MAX_SAFE_INTEGER)throw new CloudError("quota_exceeded");
  state.sequence+=1;
  const result={kind,id,version,sequence:state.sequence,payload};
  await client.query(`INSERT INTO cloud_records(account_id,kind,id,version,sequence,payload) VALUES($1,$2,$3,$4,$5,$6)
    ON CONFLICT(account_id,kind,id) DO UPDATE SET version=EXCLUDED.version,sequence=EXCLUDED.sequence,payload=EXCLUDED.payload`,[accountID,kind,id,version,state.sequence,payload===null?null:JSON.stringify(payload)]);
  await client.query("INSERT INTO cloud_changes(account_id,sequence,kind,id,version,payload) VALUES($1,$2,$3,$4,$5,$6)",[accountID,state.sequence,kind,id,version,payload===null?null:JSON.stringify(payload)]);
  await client.query("UPDATE cloud_libraries SET sequence=$2 WHERE account_id=$1",[accountID,state.sequence]);
  return result;
}
export class CloudRecords {
  readonly database:CloudDatabase;
  constructor(database:CloudDatabase){this.database=database;}
  async push(scope:CloudScope,epoch:string,raw:Mutation):Promise<MutationResult>{
    const mutation=validateMutation(raw),fingerprint=createHash("sha256").update(canonical(mutation)).digest("hex");
    return this.database.device(scope,epoch,async(client,state)=>{
      const receipt=(await client.query<{request_hash:string;result:MutationResult}>("SELECT request_hash,result FROM cloud_operations WHERE account_id=$1 AND operation_id=$2",[scope.accountID,mutation.operationID])).rows[0];
      if(receipt){if(receipt.request_hash!==fingerprint)throw new CloudError("operation_reused");return receipt.result;}
      const row=(await client.query("SELECT kind,id,version,sequence,payload FROM cloud_records WHERE account_id=$1 AND kind=$2 AND id=$3",[scope.accountID,mutation.kind,mutation.id])).rows[0];
      const current:CloudRecord=row?record(row):{kind:mutation.kind,id:mutation.id,version:0,sequence:0,payload:null};
      let result:MutationResult;
      if(current.version!==mutation.baseVersion||(current.version>0&&current.payload===null&&mutation.payload!==null))result={outcome:"conflict",record:current};
      else{
        let payload=mutation.payload;
        await this.validateReferences(client,scope.accountID,mutation.kind,payload);
        if(mutation.kind==="opening"&&payload!==null){
          const history=(await client.query("SELECT payload FROM cloud_records WHERE account_id=$1 AND kind='historyPreference' AND id='global'",[scope.accountID])).rows[0]?.payload;
          if(history?.enabled===false||Date.parse(String(payload.date))<Date.now()-90*86400000)payload=null;
        }
        const saved=current.version>0&&canonical(current.payload)===canonical(payload)?current:await appendRecord(client,scope.accountID,state,mutation.kind,mutation.id,current.version+1,payload);
        result={outcome:"applied",record:saved};
        if(mutation.kind==="historyPreference"&&payload?.enabled===false){
          const openings=await client.query("SELECT id,version FROM cloud_records WHERE account_id=$1 AND kind='opening' AND payload IS NOT NULL",[scope.accountID]);
          for(const opening of openings.rows)await appendRecord(client,scope.accountID,state,"opening",opening.id,Number(opening.version)+1,null);
        }
      }
      await client.query("INSERT INTO cloud_operations(account_id,operation_id,request_hash,result) VALUES($1,$2,$3,$4)",[scope.accountID,mutation.operationID,fingerprint,JSON.stringify(result)]);
      return result;
    });
  }
  private async validateReferences(client:PoolClient,accountID:string,kind:RecordKind,payload:Payload):Promise<void>{
    if(payload===null)return;
    const references:Array<[RecordKind,string]>=[];
    if(kind==="card"){
      if(payload.sourceID)references.push(["source",String(payload.sourceID)]);
      if(payload.folderID)references.push(["folder",String(payload.folderID)]);
      for(const id of payload.tagIDs as string[])references.push(["tag",id]);
      for(const id of payload.attachmentIDs as string[]){
        if(!(await client.query("SELECT id FROM cloud_media WHERE account_id=$1 AND id=$2",[accountID,id])).rowCount)throw new CloudError("missing_media");
      }
    }
    if(kind==="source")for(const id of payload.authorIDs as string[])references.push(["author",id]);
    if(kind==="opening"||kind==="cardReturn")references.push(["card",String(payload.cardID)]);
    for(const [related,id]of references)if(!(await client.query("SELECT id FROM cloud_records WHERE account_id=$1 AND kind=$2 AND id=$3",[accountID,related,id])).rowCount)throw new CloudError("invalid_record");
  }
}
