import assert from "node:assert/strict";
import {test} from "node:test";
import {randomUUID} from "node:crypto";
import {Pool} from "pg";
import {migrate} from "../src/database/migrate.ts";
import {buildApp} from "../src/app.ts";
import {PostgresAccountRepository} from "../src/accounts/postgres-account-repository.ts";
import {PostgresDevelopmentIdentities} from "../src/auth/development-identities.ts";
import {DevelopmentAuthProvider} from "../src/auth/development-provider.ts";
import {AccountDeletionWorker} from "../src/accounts/lifecycle.ts";

test("phone change and recovery preserve identity across provider restart; pending deletion blocks reactivation and retries", {skip: !process.env.TEST_DATABASE_URL}, async () => {
  const pool = new Pool({connectionString: process.env.TEST_DATABASE_URL,max:2});
  await migrate(pool,new URL("../migrations/",import.meta.url));
  const client = await pool.connect();
  const accounts = new PostgresAccountRepository(client), identities = new PostgresDevelopmentIdentities(client);
  const auth = new DevelopmentAuthProvider("test",Date.now,identities);
  const app = buildApp({auth,accounts,lifecycle:{provider:auth,repository:accounts}});
  try {
    await client.query("BEGIN");
    await client.query("DELETE FROM development_identities WHERE phone IN ('+70000000091','+70000000092')");
    const phone = "+70000000091", changed = "+70000000092", email = `${randomUUID()}@example.test`;
    await auth.requestCode(phone);
    const initial = await auth.verifyCode(phone,"123456"), account = await accounts.findOrCreate(initial.identity);
    const headers = {authorization:`Bearer ${initial.accessToken}`};
    for (const [kind,value] of [["email",email],["phone",changed]]) {
      assert.equal((await app.inject({method:"POST",url:`/v1/account/${kind}/request`,headers,payload:{value}})).statusCode,202);
      assert.equal((await app.inject({method:"POST",url:`/v1/account/${kind}/verify`,headers,payload:{code:"000000"}})).statusCode,401);
      const response = await app.inject({method:"POST",url:`/v1/account/${kind}/verify`,headers,payload:{code:"123456"}});
      assert.equal(response.statusCode,200); assert.equal(response.json().confirmed,true); assert.equal(response.json().account.id,account.id);
    }
    const restarted = new DevelopmentAuthProvider("test",Date.now,identities);
    await restarted.requestCode(changed);
    const afterRestart = await restarted.verifyCode(changed,"123456");
    assert.equal(afterRestart.identity.subject,initial.identity.subject);
    await restarted.requestRecovery(email);
    const recovered = await restarted.verifyRecovery(email,"123456");
    assert.equal((await accounts.findOrCreate(recovered.identity)).id,account.id);
    assert.equal(recovered.identity.phone,changed);
    const response = await app.inject({method:"DELETE",url:"/v1/account",headers});
    assert.equal(response.statusCode,202);
    await assert.rejects(accounts.findOrCreate(recovered.identity),{code:"unauthorized"});
    assert.equal((await app.inject({method:"GET",url:"/v1/account",headers})).statusCode,401);
    const failed = Object.create(auth) as DevelopmentAuthProvider;
    failed.deleteIdentity = async () => { throw new Error("temporary"); };
    await assert.rejects(new AccountDeletionWorker(accounts,failed,"development").run());
    assert.equal((await accounts.pendingDeletions()).some(job => job.id===account.id),true);
    await new AccountDeletionWorker(accounts,auth,"development").run();
    assert.equal(await identities.get(initial.identity.subject),undefined);
    await assert.rejects(accounts.findOrCreate(initial.identity),{code:"unauthorized"});
    const row = (await client.query("SELECT phone,recovery_email,deletion_status FROM accounts WHERE id=$1",[account.id])).rows[0];
    assert.deepEqual(row,{phone:null,recovery_email:null,deletion_status:"deleted"});
  } finally { await app.close(); await client.query("ROLLBACK"); client.release(); await pool.end(); }
});
