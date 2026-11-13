import test from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {cloudFixture} from "./cloud-fixture.ts";
import {CloudDevices} from "../src/cloud/devices.ts";
import {CloudRecords} from "../src/cloud/records.ts";
import {CloudReturns} from "../src/returns/service.ts";
import {CloudPushWorker} from "../src/notifications/worker.ts";
import {defaultSettings} from "../src/returns/models.ts";
import type {PushMessage} from "../src/notifications/provider.ts";

test("push waits for ready primary, pauses on logout and never repeats ambiguous sends",{skip:!process.env.TEST_DATABASE_URL},async()=>{
  const f=await cloudFixture(),devices=new CloudDevices(f.database),records=new CloudRecords(f.database),now=Date.now(),sent:PushMessage[]=[];
  const returns=new CloudReturns(f.database,()=>now),worker=new CloudPushWorker(f.database,returns,{async send(message){sent.push(message);return "unknown";}},()=>now);
  try{
    const token="a".repeat(64);await devices.register(f.scope.accountID,{id:f.scope.deviceID,name:"One",timeZone:"UTC",pushToken:token});await devices.selectPrimary(f.scope,f.scope.deviceID);
    await records.push(f.scope,f.epoch,{operationID:randomUUID(),kind:"returnSettings",id:"global",baseVersion:0,payload:{...defaultSettings(),enabled:true,notificationsEnabled:true}});
    const id=randomUUID();await records.push(f.scope,f.epoch,{operationID:randomUUID(),kind:"card",id,baseVersion:0,payload:{id,text:"Private quote",title:"",comment:"",page:"",tagIDs:[],attachmentIDs:[],createdAt:new Date(now-86400000).toISOString(),updatedAt:new Date(now-86400000).toISOString(),isFavorite:false,isHidden:false,allowsReturns:true}});
    const slot={id:"cloud-due-test",date:new Date(now-1000).toISOString()};
    await f.pool.query("INSERT INTO cloud_return_slots VALUES($1,$2,$3,$4,$5,$6,false)",[f.scope.accountID,slot.id,new Date(now-1000),slot,{cardID:id,reason:"firstReturn"},randomUUID()]);
    await worker.refreshAccount(f.scope.accountID);assert.equal(sent.length,0);
    await devices.ready(f.scope,f.epoch);await devices.pause(f.scope);await worker.refreshAccount(f.scope.accountID);assert.equal(sent.length,0);
    await devices.register(f.scope.accountID,{id:f.scope.deviceID,name:"One",timeZone:"UTC",pushToken:token});await devices.ready(f.scope,f.epoch);
    await Promise.all([worker.refreshAccount(f.scope.accountID),worker.refreshAccount(f.scope.accountID)]);assert.equal(sent.length,1);assert.equal(sent[0]?.token,token);
    await worker.refreshAccount(f.scope.accountID);assert.equal(sent.length,1);
    assert.equal((await f.pool.query("SELECT state FROM cloud_push_outbox WHERE account_id=$1 AND slot_id=$2",[f.scope.accountID,slot.id])).rows[0].state,"unknown");
    await devices.register(f.scope.accountID,{id:f.scope.deviceID,name:"One",timeZone:"UTC",pushToken:null});
    assert.equal((await f.pool.query("SELECT push_token FROM cloud_devices WHERE account_id=$1 AND id=$2",[f.scope.accountID,f.scope.deviceID])).rows[0].push_token,null);
  }finally{await f.cleanup();}
});
