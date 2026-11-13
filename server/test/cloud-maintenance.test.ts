import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID,createHash} from "node:crypto";
import {mkdtemp,rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {cloudFixture,tagMutation} from "./cloud-fixture.ts";
import {CloudMaintenance} from "../src/cloud/maintenance.ts";
import {CloudRecords} from "../src/cloud/records.ts";
import {CloudLibrary} from "../src/cloud/library.ts";
import {CloudMedia} from "../src/cloud/media/service.ts";
import {FileObjectStore} from "../src/cloud/media/file-object-store.ts";

test("history is redacted from journal and receipts; quotas rollback mutations; account deletion removes objects",{skip:!process.env.TEST_DATABASE_URL},async()=>{
  const f=await cloudFixture(),root=await mkdtemp(join(tmpdir(),"reed-retention-")),objects=new FileObjectStore(root),maintenance=new CloudMaintenance(f.database,objects),records=new CloudRecords(f.database);
  try{
    const cardID=randomUUID();await records.push(f.scope,f.epoch,{operationID:randomUUID(),kind:"card",id:cardID,baseVersion:0,payload:{id:cardID,text:"Книга",title:"",comment:"",page:"",tagIDs:[],attachmentIDs:[],createdAt:new Date().toISOString(),updatedAt:new Date().toISOString(),isFavorite:false,isHidden:false,allowsReturns:true}});
    const id=randomUUID(),operation={operationID:randomUUID(),kind:"opening" as const,id,baseVersion:0,payload:{id,cardID,date:new Date().toISOString(),origin:"manual"}};
    await records.push(f.scope,f.epoch,operation);
    await records.push(f.scope,f.epoch,{operationID:randomUUID(),kind:"opening",id,baseVersion:1,payload:null});
    const replay=await records.push(f.scope,f.epoch,operation);assert.equal(replay.record.payload,null);
    assert.equal((await f.pool.query("SELECT COUNT(*)::int AS count FROM cloud_changes WHERE account_id=$1 AND kind='opening' AND payload IS NOT NULL",[f.scope.accountID])).rows[0].count,0);
    const expiredID=randomUUID(),expired={...operation,operationID:randomUUID(),id:expiredID,payload:{...operation.payload,id:expiredID}};
    await records.push(f.scope,f.epoch,expired);
    const oldDate=JSON.stringify(new Date(Date.now()-91*86400000).toISOString());
    await f.pool.query("UPDATE cloud_records SET payload=jsonb_set(payload,'{date}',$3::jsonb) WHERE account_id=$1 AND kind='opening' AND id=$2",[f.scope.accountID,expiredID,oldDate]);
    await f.pool.query("UPDATE cloud_changes SET payload=jsonb_set(payload,'{date}',$3::jsonb) WHERE account_id=$1 AND kind='opening' AND id=$2",[f.scope.accountID,expiredID,oldDate]);
    await maintenance.account(f.scope.accountID);
    assert.equal((await records.push(f.scope,f.epoch,expired)).record.payload,null);
    assert.equal((await f.pool.query("SELECT payload FROM cloud_records WHERE account_id=$1 AND kind='opening' AND id=$2",[f.scope.accountID,expiredID])).rows[0].payload,null);
    const before=await new CloudLibrary(f.database).summary(f.scope.accountID);
    await assert.rejects(new CloudRecords(f.database,1).push(f.scope,f.epoch,tagMutation()),{code:"quota_exceeded"});
    assert.equal((await new CloudLibrary(f.database).summary(f.scope.accountID)).sequence,before.sequence);
    const upload=randomUUID();await objects.append({accountID:f.scope.accountID,epoch:f.epoch},upload,"original",0,Buffer.from("private"));
    await f.pool.query("UPDATE accounts SET deletion_status='pending' WHERE id=$1",[f.scope.accountID]);
    await maintenance.deleteAccount(f.scope.accountID);
    assert.equal(await objects.inspect({accountID:f.scope.accountID,epoch:f.epoch},"upload",upload,"original"),undefined);
    assert.equal((await f.pool.query("SELECT COUNT(*)::int AS count FROM cloud_records WHERE account_id=$1",[f.scope.accountID])).rows[0].count,0);
  }finally{await f.cleanup();await rm(root,{recursive:true,force:true});}
});

test("unreferenced media expires through a committed deletion queue",{skip:!process.env.TEST_DATABASE_URL},async()=>{
  const f=await cloudFixture(),root=await mkdtemp(join(tmpdir(),"reed-media-gc-")),objects=new FileObjectStore(root),maintenance=new CloudMaintenance(f.database,objects),media=new CloudMedia(f.database,objects);
  try{
    const bytes=Buffer.from("photo"),part={size:bytes.length,sha256:createHash("sha256").update(bytes).digest("hex")},id=randomUUID();
    const upload=await media.begin(f.scope,f.epoch,{id,original:part,thumbnail:part});
    for(const variant of ["original","thumbnail"] as const)await media.append(f.scope,f.epoch,upload.id,variant,0,bytes);
    await media.finish(f.scope,f.epoch,upload.id);
    await maintenance.account(f.scope.accountID);
    await f.pool.query("UPDATE cloud_uploads SET expires_at=now()-interval '1 day' WHERE account_id=$1",[f.scope.accountID]);
    await f.pool.query("UPDATE cloud_media SET unreferenced_since=now()-interval '8 days' WHERE account_id=$1",[f.scope.accountID]);
    await maintenance.account(f.scope.accountID);
    await assert.rejects(media.manifest(f.scope,f.epoch,id),{code:"not_found"});
    assert.ok(await objects.inspect({accountID:f.scope.accountID,epoch:f.epoch},"media",id,"original"));
    await maintenance.account(f.scope.accountID);
    assert.equal(await objects.inspect({accountID:f.scope.accountID,epoch:f.epoch},"media",id,"original"),undefined);
    const reset=await new CloudLibrary(f.database).reset(f.scope,f.epoch);assert.notEqual(reset.epoch,f.epoch);
    assert.equal((await f.pool.query("SELECT COUNT(*)::int AS count FROM cloud_object_cleanup WHERE account_id=$1",[f.scope.accountID])).rows[0].count,1);
  }finally{await f.cleanup();await rm(root,{recursive:true,force:true});}
});
