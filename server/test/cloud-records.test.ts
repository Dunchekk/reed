import {test} from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {CloudRecords} from "../src/cloud/records.ts";
import {cloudFixture,tagMutation} from "./cloud-fixture.ts";

test("lost responses replay exactly once; concurrent edits conflict; deleted records cannot resurrect",{skip:!process.env.TEST_DATABASE_URL},async()=>{
  const f=await cloudFixture(),records=new CloudRecords(f.database);
  try{
    const create=tagMutation(),initial=await records.push(f.scope,f.epoch,create);
    assert.equal(initial.record.version,1);
    assert.deepEqual(await records.push(f.scope,f.epoch,create),initial);
    await assert.rejects(records.push(f.scope,f.epoch,{...create,payload:{id:create.id,name:"different"}}),{code:"operation_reused"});
    const updates=[tagMutation("A",create.id,1),tagMutation("B",create.id,1)];
    const results=await Promise.all(updates.map(value=>records.push(f.scope,f.epoch,value)));
    assert.equal(results.filter(value=>value.outcome==="applied").length,1);
    assert.equal(results.filter(value=>value.outcome==="conflict").length,1);
    const remove={...tagMutation("",create.id,2),payload:null};
    assert.equal((await records.push(f.scope,f.epoch,remove)).record.version,3);
    assert.equal((await records.push(f.scope,f.epoch,tagMutation("revive",create.id,3))).outcome,"conflict");
    assert.equal((await f.pool.query("SELECT COUNT(*)::int AS count FROM cloud_changes WHERE account_id=$1",[f.scope.accountID])).rows[0].count,3);
    await assert.rejects(records.push({...f.scope,deviceID:randomUUID()},f.epoch,tagMutation()),{code:"device_revoked"});
    await f.pool.query("UPDATE accounts SET deletion_status='pending' WHERE id=$1",[f.scope.accountID]);
    await assert.rejects(records.push(f.scope,f.epoch,tagMutation()),{code:"unauthorized"});
  }finally{await f.cleanup();}
});
