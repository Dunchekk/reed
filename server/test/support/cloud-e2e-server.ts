// Isolated opt-in fixture for Swift clients. Only synthetic identities and loopback HTTP.
import {writeFile,rm,mkdtemp} from "node:fs/promises";
import {join} from "node:path";
import {tmpdir} from "node:os";
import {cloudFixture} from "../cloud-fixture.ts";
import {buildApp} from "../../src/app.ts";
import {DevelopmentAuthProvider} from "../../src/auth/development-provider.ts";
import {PostgresAccountRepository} from "../../src/accounts/postgres-account-repository.ts";
import {CloudLibrary} from "../../src/cloud/library.ts";
import {CloudRecords} from "../../src/cloud/records.ts";
import {CloudDevices} from "../../src/cloud/devices.ts";
import {CloudMedia} from "../../src/cloud/media/service.ts";
import {FileObjectStore} from "../../src/cloud/media/file-object-store.ts";
import {CloudReturns} from "../../src/returns/service.ts";
if(!process.env.TEST_DATABASE_URL || !process.env.REED_CLOUD_E2E_CONFIG)throw new Error("Explicit test database and fixture path required");
const f=await cloudFixture(),root=await mkdtemp(join(tmpdir(),"reed-e2e-server-")),auth=new DevelopmentAuthProvider("test"),accounts=new PostgresAccountRepository(f.pool);
await auth.requestCode("+70000000029");const session=await auth.verifyCode("+70000000029","123456"),account=await accounts.findOrCreate(session.identity);
const app=buildApp({auth,accounts},{library:new CloudLibrary(f.database),records:new CloudRecords(f.database),devices:new CloudDevices(f.database),media:new CloudMedia(f.database,new FileObjectStore(root)),returns:new CloudReturns(f.database)});
const baseURL=await app.listen({host:"127.0.0.1",port:0});
await writeFile(process.env.REED_CLOUD_E2E_CONFIG,JSON.stringify({baseURL,accountID:account.id,accessToken:session.accessToken}),{mode:0o600});
console.log("Local cloud E2E fixture ready");
let stopping=false;
async function stop(){
  if(stopping)return;stopping=true;
  await app.close();await f.pool.query("DELETE FROM cloud_object_cleanup WHERE account_id=$1",[account.id]);await f.pool.query("DELETE FROM cloud_libraries WHERE account_id=$1",[account.id]);await f.pool.query("DELETE FROM accounts WHERE id=$1",[account.id]);
  await f.cleanup();await rm(root,{recursive:true,force:true});await rm(process.env.REED_CLOUD_E2E_CONFIG!,{force:true});
}
for(const signal of ["SIGINT","SIGTERM"] as const)process.once(signal,()=>{void stop().catch(()=>{process.exitCode=1;});});
