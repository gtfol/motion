import type { Metadata } from "next";

export const metadata: Metadata = { title: "Terms — motion", description: "Terms for using Motion’s fitness tracking and optional account sync." };

export default function Terms() {
  return <article className="legal">
    <h1>Terms</h1><p className="muted">Updated October 18, 2026</p>
    <p>These terms cover Motion, provided by gtfol, LLC. By using Motion, you agree to these terms. Our <a href="/privacy">privacy policy</a> explains how we handle your information.</p>
    <h2>Using Motion</h2>
    <p>Motion helps you record workouts, review measurements, and optionally sync your training log. Use it lawfully and only connect accounts, devices, and data you are authorized to use. Do not interfere with the service, attempt unauthorized access, or use it to harm others.</p>
    <h2>Health and measurement limits</h2>
    <p>Motion is a fitness tracking tool, not a medical device or a service for diagnosis, treatment, or emergencies. Measurements and summaries can be incomplete or inaccurate. They do not replace advice from a qualified health professional.</p>
    <h2>Your account and records</h2>
    <p>You remain responsible for your account security and the records you enter. You keep ownership of your data and allow us to process it as needed to provide the features you use. Keep independent copies of records that matter to you. Local-only data may be lost if you delete the app or lose access to your device.</p>
    <h2>Connected services</h2>
    <p>Google sign-in, Apple Health, Bluetooth devices, and other connected services operate under their own terms. Availability and compatibility can change. Motion is not affiliated with or endorsed by the makers of supported third-party devices unless expressly stated.</p>
    <h2>Availability and changes</h2>
    <p>We work to keep Motion useful and reliable, but cannot promise uninterrupted service or error-free records. Features may change or become unavailable. We may restrict access to protect users or address misuse. You can stop using Motion at any time and request account deletion.</p>
    <p>Nothing in these terms limits rights or remedies that cannot be excluded under applicable law. Material changes to these terms will be identified with an updated date and, where required, additional notice.</p>
    <h2>Contact</h2>
    <p>Questions about Motion or these terms: <a href="mailto:team@gtfol.dev">team@gtfol.dev</a>.</p>
  </article>;
}
