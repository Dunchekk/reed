import {test} from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {CloudDevices} from "../src/cloud/devices.ts";
import {cloudFixture} from "./cloud-fixture.ts";

test("recipient selection is exclusive; revoked device cannot silently rejoin", {skip: !process.env.TEST_DATABASE_URL}, async () => {
  const f = await cloudFixture(), devices = new CloudDevices(f.database), second = randomUUID();
  try {
    await devices.register(f.scope.accountID,{id:second,name:"Second iPhone",timeZone:"Europe/Moscow"});
    await devices.selectPrimary(f.scope,second);
    assert.deepEqual((await devices.list(f.scope)).filter(d => d.isPrimary).map(d => d.id),[second]);
    await devices.revoke(f.scope,second);
    assert.equal((await devices.list(f.scope)).length,1);
    await assert.rejects(devices.list({...f.scope,deviceID:second}),{code:"device_revoked"});
    await assert.rejects(devices.register(f.scope.accountID,{id:second,name:"Retry",timeZone:"UTC"}),{code:"device_revoked"});
    await assert.rejects(devices.selectPrimary(f.scope,randomUUID()),{code:"not_found"});
    assert.equal((await devices.list(f.scope)).filter(d => d.isPrimary).length,0);
  } finally { await f.cleanup(); }
});
