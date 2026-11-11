import {test} from "node:test";
import assert from "node:assert/strict";
import {randomUUID} from "node:crypto";
import {Pool} from "pg";
import {migrate} from "../src/database/migrate.ts";

test("cloud schema isolates account keys and enforces one notification recipient",{skip:!process.env.TEST_DATABASE_URL},async()=>{
  const pool=new Pool({connectionString:process.env.TEST_DATABASE_URL,max:2});
  try {
    await migrate(pool,new URL("../migrations/",import.meta.url));
    const client=await pool.connect();
    try {
      await client.query("BEGIN");
      const a=randomUUID(),b=randomUUID(),device=randomUUID();
      for(const account of [a,b]) {
        await client.query("INSERT INTO accounts(id,provider,provider_subject,phone) VALUES($1::uuid,'test',$1::text,'+70000000001')",[account]);
        await client.query("INSERT INTO cloud_libraries(account_id,epoch) VALUES($1,$2)",[account,randomUUID()]);
        await client.query("INSERT INTO cloud_devices(account_id,id,name,time_zone,is_primary) VALUES($1,$2,'iPhone','Europe/Moscow',true)",[account,device]);
      }
      assert.equal((await client.query("SELECT * FROM cloud_devices WHERE account_id=$1",[a])).rowCount,1);
      await assert.rejects(client.query("INSERT INTO cloud_devices(account_id,id,name,time_zone,is_primary) VALUES($1,$2,'Another','UTC',true)",[a,randomUUID()]),{code:"23505"});
    } finally { await client.query("ROLLBACK"); client.release(); }
  } finally {await pool.end();}
});
