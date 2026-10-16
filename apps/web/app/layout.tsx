import type {Metadata} from "next";
import "./style.css";
export const metadata:Metadata={title:"motion — your fitness companion",description:"Your workouts and heart rate, together.",robots:{index:false,follow:false}};
export default function Layout({children}:{children:React.ReactNode}) {
 return <html lang="en"><body><main><a className="brand" href="/"><img src="/icon.png" width="64" height="64" alt=""/><span>motion</span></a>{children}<footer>by <a href="https://gtfol.dev">gtfol</a><span>·</span><a href="/privacy">privacy</a></footer></main></body></html>;
}
