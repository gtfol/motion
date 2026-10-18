import type { Metadata } from "next";

export const metadata: Metadata = { title: "Privacy — motion", description: "How Motion handles your training log and optional account sync." };

export default function Privacy() {
  return <article className="legal">
    <h1>Your data in Motion.</h1>
    <p className="muted">Updated October 18, 2026 · gtfol, LLC</p>
    <p>Motion keeps your training log on your device. Google sign-in is optional. If you sign in, your email, name and account identifier are used to keep your account separate from other people’s accounts.</p>
    <p>Your exercises, routines, completed workouts, sets, recorded workout heart rate and training preferences sync to your account through Motion’s server on Vercel and its database on Supabase. Active workouts, Bluetooth pairing and Apple Health permissions stay on your device. Sleep history and overnight strap measurements currently stay on your device and are not included in account sync.</p>
    <p>Apple Health access is optional. You choose which data Motion can read or write and can change those permissions in iPhone Settings.</p>
    <p>Google provides sign-in. Motion does not request access to your Gmail, Drive or other Google content. We do not sell your training data or use advertising trackers.</p>
    <p>Sign out to stop syncing on a device. You can delete your account and its cloud log from account settings in Motion. This also removes that account’s local log on the device making the request; other offline copies and Apple Health records are not remotely erased. Provider backups may retain deleted data until their retention periods end.</p>
    <p>For help or a privacy request, contact <a href="mailto:team@gtfol.dev">team@gtfol.dev</a>.</p>
  </article>;
}
