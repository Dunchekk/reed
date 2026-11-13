import {connect} from "node:http2";
import {createHash,createPrivateKey,sign} from "node:crypto";
import type {KeyObject} from "node:crypto";
import {readFile} from "node:fs/promises";
import type {PushMessage,PushOutcome,PushProvider} from "./provider.ts";
export interface APNsConfiguration {keyID:string;teamID:string;topic:string;privateKey:string;sandbox:boolean}
export class APNsProvider implements PushProvider {
  private readonly config:APNsConfiguration;private readonly key:KeyObject;private cached?:{value:string;at:number};
  constructor(config:APNsConfiguration){
    this.config=config;this.key=createPrivateKey(config.privateKey);
    if(this.key.asymmetricKeyType!=="ec" || this.key.asymmetricKeyDetails?.namedCurve!=="prime256v1")throw new Error("APNs requires a P-256 key");
  }
  private token():string{
    const now=Math.floor(Date.now()/1000);if(this.cached && now-this.cached.at<3000)return this.cached.value;
    const encode=(value:unknown)=>Buffer.from(JSON.stringify(value)).toString("base64url");
    const payload=`${encode({alg:"ES256",kid:this.config.keyID})}.${encode({iss:this.config.teamID,iat:now})}`;
    const value=`${payload}.${sign("sha256",Buffer.from(payload),{key:this.key,dsaEncoding:"ieee-p1363"}).toString("base64url")}`;
    this.cached={value,at:now};return value;
  }
  async send(message:PushMessage):Promise<PushOutcome>{
    const authorization=`bearer ${this.token()}`;
    return new Promise(resolve=>{
      const session=connect(this.config.sandbox?"https://api.sandbox.push.apple.com":"https://api.push.apple.com");
      let finished=false;const done=(outcome:PushOutcome)=>{if(finished)return;finished=true;clearTimeout(timer);session.destroy();resolve(outcome);};
      const timer=setTimeout(()=>done("unknown"),10_000);
      session.on("error",()=>done("unknown"));
      session.once("connect",()=>{
        const stream=session.request({":method":"POST",":path":`/3/device/${message.token}`,authorization,
          "apns-topic":this.config.topic,"apns-push-type":"alert","apns-priority":"10","apns-id":message.id,
          "apns-expiration":String(Math.floor(message.expiresAt/1000)),"apns-collapse-id":createHash("sha256").update(message.slotID).digest("hex")});
        let status=0,body="";stream.setEncoding("utf8");stream.on("response",headers=>{status=Number(headers[":status"]);});
        stream.on("data",chunk=>{if(body.length<4096)body+=chunk;});stream.on("error",()=>done("unknown"));
        stream.on("end",()=>{
          if(status===200){done("accepted");return;}
          let reason="";try{reason=JSON.parse(body).reason??"";}catch{}
          if(status===410 || reason==="BadDeviceToken" || reason==="DeviceTokenNotForTopic")done("invalidToken");
          else if(status===429 || status>=500)done("retry");else done("rejected");
        });
        // Private card text never enters APNs, including notifications received after an offline logout.
        stream.end(JSON.stringify({aps:{alert:{title:"Reed",body:"Время вернуться к сохранённой мысли"},sound:"default"},accountID:message.accountID,cardID:message.cardID,slotID:message.slotID}));
      });
    });
  }
}
export async function configuredAPNs(env:NodeJS.ProcessEnv):Promise<APNsProvider|undefined>{
  const keys=[env.APNS_KEY_ID,env.APNS_TEAM_ID,env.APNS_TOPIC,env.APNS_KEY_PATH];
  if(keys.every(value=>!value))return undefined;
  if(keys.some(value=>!value) || !["true","false"].includes(env.APNS_SANDBOX??""))throw new Error("Complete APNs configuration is required");
  return new APNsProvider({keyID:env.APNS_KEY_ID!,teamID:env.APNS_TEAM_ID!,topic:env.APNS_TOPIC!,privateKey:await readFile(env.APNS_KEY_PATH!,"utf8"),sandbox:env.APNS_SANDBOX==="true"});
}
