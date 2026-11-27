import PostalMime from "postal-mime";
import { buildPayload } from "./payload";

export interface Env {
  /** The gateway's hooks host, e.g. https://hooks.example.com */
  GATEWAY_URL: string;
  /** Worker secret, the same value as NUO_MAIL_SECRET on the gateway. */
  MAIL_SECRET: string;
  /** A verified Email Routing destination that gets the mail when the gateway cannot take it. */
  FALLBACK_FORWARD?: string;
}

/** The part of Cloudflare's ForwardableEmailMessage this Worker uses. */
export interface IncomingMessage {
  readonly to: string;
  readonly raw: ReadableStream<Uint8Array>;
  setReject(reason: string): void;
  forward(rcptTo: string): Promise<unknown>;
}

export async function deliver(message: IncomingMessage, env: Env, fetcher: typeof fetch = fetch): Promise<"accepted" | "rejected" | "forwarded" | "dropped"> {
  const email = await PostalMime.parse(message.raw);
  const payload = buildPayload(message.to, email);
  let status = 0;
  try {
    const res = await fetcher(`${env.GATEWAY_URL.replace(/\/+$/, "")}/mail`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${env.MAIL_SECRET}` },
      body: JSON.stringify(payload),
    });
    status = res.status;
  } catch (e) {
    console.error("gateway unreachable:", e);
  }
  if (status >= 200 && status < 300) return "accepted";
  // Only a recipient the gateway does not know bounces; any other failure must not lose the mail.
  if (status === 404) {
    message.setReject("Unknown recipient");
    return "rejected";
  }
  console.error(`gateway answered ${status || "nothing"} for ${message.to}`);
  if (env.FALLBACK_FORWARD) {
    await message.forward(env.FALLBACK_FORWARD);
    return "forwarded";
  }
  return "dropped";
}

export default {
  async email(message: ForwardableEmailMessage, env: Env): Promise<void> {
    await deliver(message, env);
  },
};
