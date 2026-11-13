export interface PushMessage {id:string;token:string;accountID:string;cardID:string;slotID:string;expiresAt:number}
export type PushOutcome = "accepted" | "invalidToken" | "retry" | "rejected" | "unknown";
export interface PushProvider {send(message:PushMessage):Promise<PushOutcome>}
