import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {cloudFixture,tagMutation} from "./cloud-fixture.ts";
import {CloudDevices} from "../src/cloud/devices.ts";
import {CloudRecords} from "../src/cloud/records.ts";
import {CloudReturns} from "../src/returns/service.ts";
import {defaultSettings} from "../src/returns/models.ts";

test("two devices share persisted returns, past slots survive replanning and timezone follows primary",{skip:!process.env.TEST_DATABASE_URL},async()=>{
  const f=await cloudFixture(),devices=new CloudDevices(f.database),records=new CloudRecords(f.database);
  let now=Date.parse("2026-11-12T00:00:00Z");const returns=new CloudReturns(f.database,()=>now);
  try{
    await devices.selectPrimary(f.scope,f.scope.deviceID);
    const second=await devices.register(f.scope.accountID,{id:randomUUID(),name:"Second",timeZone:"Europe/Moscow"});
    const settings={...defaultSettings(),enabled:true,notificationsEnabled:true};
    await records.push(f.scope,f.epoch,{operationID:randomUUID(),kind:"returnSettings",id:"global",baseVersion:0,payload:settings});
    for(let i=0;i<20;i++){
      const id=randomUUID();await records.push(f.scope,f.epoch,{operationID:randomUUID(),kind:"card",id,baseVersion:0,payload:{id,text:`Текст ${i}`,title:"",comment:"",page:"",tagIDs:[],attachmentIDs:[],createdAt:"2026-10-01T00:00:00Z",updatedAt:"2026-10-01T00:00:00Z",isFavorite:false,isHidden:false,allowsReturns:true}});
    }
    const first=await returns.plan(f.scope,f.epoch),other=await returns.plan({...f.scope,deviceID:second.id},f.epoch);
    assert.deepEqual(first,other);assert.equal(first.entries.length,21);assert.ok(first.entries.every(item=>item.decision.cardID));
    const original=first.entries[0]!;now=Date.parse(original.slot.date)+1000;
    await records.push(f.scope,f.epoch,tagMutation());
    const replanned=await returns.plan(f.scope,f.epoch);
    assert.deepEqual(replanned.entries.find(item=>item.slot.id===original.slot.id),original);
    assert.ok(replanned.entries.filter(item=>Date.parse(item.slot.date)>now).every(item=>item.decision.cardID!==original.decision.cardID || Date.parse(item.slot.date)-Date.parse(original.slot.date)>=72*3600000));
    await devices.selectPrimary(f.scope,second.id);
    assert.equal((await returns.plan(f.scope,f.epoch)).timeZone,"Europe/Moscow");
    await devices.revoke(f.scope,second.id);
    const paused=await returns.plan(f.scope,f.epoch);assert.equal(paused.issue,"noPrimaryDevice");assert.ok(paused.entries.every(item=>Date.parse(item.slot.date)<=now));
  }finally{await f.cleanup();}
});
