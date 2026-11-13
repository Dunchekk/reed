import {randomUUID} from "node:crypto";
import {Pool} from "pg";
import {migrate} from "../src/database/migrate.ts";
import {CloudDatabase} from "../src/cloud/database.ts";
import type {CloudScope,Mutation} from "../src/cloud/contracts.ts";

export async function cloudFixture(){
  const pool=new Pool({connectionString:process.env.TEST_DATABASE_URL,max:5});
  await migrate(pool,new URL("../migrations/",import.meta.url));
  const accountID=randomUUID(),deviceID=randomUUID(),epoch=randomUUID();
  await pool.query("INSERT INTO accounts(id,provider,provider_subject,phone) VALUES($1::uuid,'cloud-test',$1::text,'+70000000001')",[accountID]);
  await pool.query("INSERT INTO cloud_libraries(account_id,epoch) VALUES($1,$2)",[accountID,epoch]);
  await pool.query("INSERT INTO cloud_devices(account_id,id,name,time_zone) VALUES($1,$2,'Test phone','UTC')",[accountID,deviceID]);
  const scope:CloudScope={accountID,deviceID},database=new CloudDatabase(pool);
  return {pool,database,scope,epoch,async cleanup(){await pool.query("DELETE FROM cloud_object_cleanup WHERE account_id=$1",[accountID]);await pool.query("DELETE FROM cloud_libraries WHERE account_id=$1",[accountID]);await pool.query("DELETE FROM accounts WHERE id=$1",[accountID]);await pool.end();}};
}
export function tagMutation(name="Тема",id:string=randomUUID(),baseVersion=0):Mutation{return {operationID:randomUUID(),kind:"tag",id,baseVersion,payload:{id,name}};}
