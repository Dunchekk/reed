import {test} from "node:test";
import assert from "node:assert/strict";
import {createHash,randomUUID} from "node:crypto";
import {mkdtemp,rm} from "node:fs/promises";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {CloudMedia} from "../src/cloud/media/service.ts";
import {FileObjectStore} from "../src/cloud/media/file-object-store.ts";
import {cloudFixture} from "./cloud-fixture.ts";

test("upload survives service restart; unverified media stays private; quota includes reservations", {skip:!process.env.TEST_DATABASE_URL}, async () => {
  const f = await cloudFixture(), root = await mkdtemp(join(tmpdir(),"reed-media-"));
  const bytes = Buffer.from("synthetic photograph"), part = {size:bytes.length,sha256:createHash("sha256").update(bytes).digest("hex")};
  const manifest = {id:randomUUID(),original:part,thumbnail:part}, store = new FileObjectStore(root);
  let media = new CloudMedia(f.database,store,bytes.length*2);
  try {
    const first = await media.begin(f.scope,f.epoch,manifest);
    await assert.rejects(media.begin(f.scope,f.epoch,{...manifest,id:randomUUID()}),{code:"quota_exceeded"});
    await media.append(f.scope,f.epoch,first.id,"original",0,bytes.subarray(0,5));
    media = new CloudMedia(f.database,store);
    const resumed = await media.begin(f.scope,f.epoch,manifest);
    assert.equal(resumed.id,first.id); assert.equal(resumed.originalOffset,5);
    await assert.rejects(media.manifest(f.scope,f.epoch,manifest.id),{code:"not_found"});
    await assert.rejects(media.finish(f.scope,f.epoch,first.id),{code:"corrupted_media"});
    await media.append(f.scope,f.epoch,first.id,"original",5,bytes.subarray(5));
    await media.append(f.scope,f.epoch,first.id,"thumbnail",0,bytes);
    await media.finish(f.scope,f.epoch,first.id);
    await media.finish(f.scope,f.epoch,first.id);
    assert.deepEqual(await media.manifest(f.scope,f.epoch,manifest.id),manifest);
    assert.deepEqual(await media.read(f.scope,f.epoch,manifest.id,"original",4,6),bytes.subarray(4,10));
    await assert.rejects(media.begin(f.scope,f.epoch,{...manifest,thumbnail:{...part,size:part.size+1}}),{code:"corrupted_media"});
    await assert.rejects(media.read({...f.scope,deviceID:randomUUID()},f.epoch,manifest.id,"original",0,5),{code:"device_revoked"});
  } finally { await f.cleanup(); await rm(root,{recursive:true,force:true}); }
});
