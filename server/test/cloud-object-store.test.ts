import {test} from "node:test";
import assert from "node:assert/strict";
import {createHash,randomUUID} from "node:crypto";
import {mkdtemp,rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {FileObjectStore} from "../src/cloud/media/file-object-store.ts";

test("private objects resume partial writes, reject divergent retries, and publish idempotently", async () => {
  const root = await mkdtemp(join(tmpdir(),"reed-objects-"));
  const store = new FileObjectStore(root), scope = {accountID:randomUUID(),epoch:randomUUID()}, upload = randomUUID(), media = randomUUID();
  const data = Buffer.from("synthetic image bytes"), part = {size:data.length,sha256:createHash("sha256").update(data).digest("hex")};
  try {
    await store.append(scope,upload,"original",0,data.subarray(0,7));
    await store.append(scope,upload,"original",0,data);
    await store.append(scope,upload,"original",0,data);
    await assert.rejects(store.append(scope,upload,"original",0,Buffer.from("different")),{code:"corrupted_media"});
    await assert.rejects(store.publish(scope,upload,media,"original",{...part,sha256:"0".repeat(64)}),{code:"corrupted_media"});
    await store.publish(scope,upload,media,"original",part);
    await store.publish(scope,upload,media,"original",part);
    assert.deepEqual(await store.read(scope,media,"original",3,5),data.subarray(3,8));
    assert.equal(await store.inspect({...scope,accountID:randomUUID()},"media",media,"original"),undefined);
    await assert.rejects(store.removeAccount("../escape"),{code:"invalid_record"});
  } finally { await rm(root,{recursive:true,force:true}); }
});
