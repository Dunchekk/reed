import {test} from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {mkdtemp,rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {buildApp} from "../src/app.ts";
import {DevelopmentAuthProvider} from "../src/auth/development-provider.ts";
import {PostgresAccountRepository} from "../src/accounts/postgres-account-repository.ts";
import {CloudLibrary} from "../src/cloud/library.ts";
import {CloudRecords} from "../src/cloud/records.ts";
import {CloudDevices} from "../src/cloud/devices.ts";
import {CloudMedia} from "../src/cloud/media/service.ts";
import {FileObjectStore} from "../src/cloud/media/file-object-store.ts";
import {cloudFixture,tagMutation} from "./cloud-fixture.ts";

test("HTTP cloud routes require identity, scope devices, and reject oversized chunks", {skip:!process.env.TEST_DATABASE_URL}, async () => {
  const f = await cloudFixture(), root = await mkdtemp(join(tmpdir(),"reed-cloud-http-"));
  const auth = new DevelopmentAuthProvider("test"), accounts = new PostgresAccountRepository(f.pool);
  const app = buildApp({auth,accounts},{library:new CloudLibrary(f.database),records:new CloudRecords(f.database),
    devices:new CloudDevices(f.database),media:new CloudMedia(f.database,new FileObjectStore(root))});
  let accountID: string | undefined;
  try {
    assert.equal((await app.inject({url:"/v1/cloud"})).statusCode,401);
    await auth.requestCode("+70000000019");
    const session = await auth.verifyCode("+70000000019","123456");
    accountID = (await accounts.findOrCreate(session.identity)).id;
    const deviceID = randomUUID(), headers = {authorization:`Bearer ${session.accessToken}`,"x-reed-device":deviceID};
    const summary = (await app.inject({url:"/v1/cloud",headers})).json();
    const transferHeaders = {...headers,"x-reed-epoch":summary.epoch};
    assert.equal((await app.inject({method:"POST",url:"/v1/cloud/mutations",headers:transferHeaders,payload:tagMutation()})).statusCode,403);
    assert.equal((await app.inject({method:"POST",url:"/v1/cloud/devices",headers,payload:{id:deviceID,name:"iPhone",timeZone:"UTC"}})).statusCode,200);
    const mutation = tagMutation();
    assert.equal((await app.inject({method:"POST",url:"/v1/cloud/mutations",headers:transferHeaders,payload:mutation})).json().outcome,"applied");
    const changes = (await app.inject({url:"/v1/cloud/changes",headers:transferHeaders})).json();
    assert.equal(changes.records[0].id,mutation.id);
    assert.equal((await app.inject({method:"PUT",url:`/v1/cloud/uploads/${randomUUID()}/original?offset=0`,headers:{...transferHeaders,"content-type":"application/octet-stream"},payload:Buffer.alloc(512*1024+1)})).statusCode,413);
    assert.equal((await app.inject({url:"/v1/cloud/changes",headers:{...transferHeaders,"x-reed-epoch":f.epoch}})).json().error.code,"epoch_changed");
  } finally {
    await app.close();
    if (accountID) { await f.pool.query("DELETE FROM cloud_libraries WHERE account_id=$1",[accountID]); await f.pool.query("DELETE FROM accounts WHERE id=$1",[accountID]); }
    await f.cleanup(); await rm(root,{recursive:true,force:true});
  }
});
