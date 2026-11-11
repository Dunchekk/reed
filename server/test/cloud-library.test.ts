import {test} from "node:test";
import assert from "node:assert/strict";
import {CloudLibrary} from "../src/cloud/library.ts";
import {CloudRecords} from "../src/cloud/records.ts";
import {cloudFixture,tagMutation} from "./cloud-fixture.ts";

test("cursor preserves intervening versions; reset fences out old devices", {skip: !process.env.TEST_DATABASE_URL}, async () => {
  const f = await cloudFixture(), library = new CloudLibrary(f.database), records = new CloudRecords(f.database);
  try {
    const first = tagMutation("v1");
    await records.push(f.scope,f.epoch,first);
    const page1 = await library.pull(f.scope,f.epoch,0,1);
    await records.push(f.scope,f.epoch,tagMutation("v2",first.id,1));
    await records.push(f.scope,f.epoch,tagMutation("v3",first.id,2));
    const page2 = await library.pull(f.scope,f.epoch,page1.cursor,1);
    assert.equal(page2.records[0]?.payload?.name,"v2");
    assert.equal(page2.hasMore,true);
    const page3 = await library.pull(f.scope,f.epoch,page2.cursor,1);
    assert.equal(page3.records[0]?.payload?.name,"v3");
    assert.equal(page3.hasMore,false);
    const reset = await library.reset(f.scope,f.epoch);
    assert.notEqual(reset.epoch,f.epoch);
    assert.equal(reset.sequence,0);
    await assert.rejects(records.push(f.scope,f.epoch,first),{code:"epoch_changed"});
    await assert.rejects(library.pull(f.scope,f.epoch,0,10),{code:"epoch_changed"});
    assert.equal((await library.pull(f.scope,reset.epoch,0,10)).records.length,0);
  } finally { await f.cleanup(); }
});
