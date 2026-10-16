import {headers} from "next/headers";
import {configured,getAuth} from "../../lib/auth";
import {authorization} from "../../lib/native";
import Connect from "./connect";
export const dynamic="force-dynamic";
export default async function Page({searchParams}:{searchParams:Promise<Record<string,string|string[]|undefined>>}) {
 const parsed=authorization.safeParse(await searchParams);
 if(!parsed.success) return <section><h1>Open Motion to sign in.</h1><p>Start from account settings in the iPhone app.</p></section>;
 if(!configured()) return <section><h1>Almost ready.</h1><p>Motion sign-in is being set up. Your log stays saved on your iPhone.</p></section>;
 try {
  const session=await getAuth().api.getSession({headers:await headers(),query:{disableCookieCache:true}});
  return <Connect request={parsed.data} user={session?{id:session.user.id,email:session.user.email}:null}/>;
 } catch {return <section><h1>Try again in a moment.</h1><p>We couldn’t connect to your account. Return to Motion and try again.</p></section>;}
}
