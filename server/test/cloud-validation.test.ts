import {test} from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {validateMutation,validateManifest} from "../src/cloud/validation.ts";

test("cloud mutation uses the shared fixture and rejects forged fields, unsafe versions and mismatched ids",async()=>{
  const fixture=JSON.parse(await readFile(new URL("../../contracts/fixtures/cloud-mutation.json",import.meta.url),"utf8"));
  assert.equal(validateMutation(fixture).payload?.name,"Тема");
  for(const input of [{...fixture,accountID:"other"},{...fixture,baseVersion:2**53},{...fixture,payload:{...fixture.payload,id:"33333333-3333-4333-8333-333333333333"}},{...fixture,payload:undefined}])assert.throws(()=>validateMutation(input));
  assert.equal(validateMutation({...fixture,payload:null}).payload,null);
});
test("cloud media is bounded and content-addressed by a complete sha256",()=>{
  const part={size:20,sha256:"a".repeat(64)},id="11111111-1111-4111-8111-111111111111";
  assert.equal(validateManifest({id,original:part,thumbnail:part}).original.size,20);
  assert.throws(()=>validateManifest({id,original:{...part,size:50*1024*1024},thumbnail:part}));
  assert.throws(()=>validateManifest({id,original:{...part,sha256:"a"},thumbnail:part}));
});
