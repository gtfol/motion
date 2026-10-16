"use client";
import {useState} from "react";
import {createAuthClient} from "better-auth/react";
const auth=createAuthClient();
export default function Connect({request,user}:{request:{code_challenge:string;state:string};user:{id:string;email:string}|null}) {
 const [busy,setBusy]=useState(false),[message,setMessage]=useState("");
 async function signIn() {
  setBusy(true);setMessage("");
  try {
   const callbackURL="/connect?"+new URLSearchParams(request);
   const result=await auth.signIn.social({provider:"google",callbackURL,errorCallbackURL:"/connect-error"});
   if(result.error) throw new Error();
  } catch {setBusy(false);setMessage("Couldn’t connect to Google. Please try again.");}
 }
 async function connect() {
  setBusy(true);setMessage("");
  try {
   const response=await fetch("/api/native/authorize",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({...request,expectedUserId:user!.id})});
   const data=await response.json();
   if(!response.ok) throw new Error(data.error || "Try again.");
   const callback=new URL(data.callbackURL);
   if(callback.protocol!=="dev.gtfol.vitals:" || callback.hostname!=="auth" || callback.pathname!=="/callback") throw new Error("Couldn’t open Motion.");
   window.location.assign(callback.toString());
   setMessage("Return to Motion to finish signing in.");
  } catch(error) {setMessage(error instanceof Error?error.message:"Try again.");}
  finally {setBusy(false);}
 }
 return <section><p className="eyebrow">your training, together</p><h1>{user?"Return to Motion.":"Sign in to Motion."}</h1><p>Keep your workout log in sync across your devices.</p>
 {user?<><p className="account">{user.email}</p><button disabled={busy} onClick={connect}>Continue to Motion</button><button className="secondary" disabled={busy} onClick={signIn}>Use another Google account</button></>:<button disabled={busy} onClick={signIn}>Continue with Google</button>}
 <p role="status" aria-live="polite" className="muted">{message || (busy?"Connecting…":"Your training log is private to your account.")}</p></section>;
}
