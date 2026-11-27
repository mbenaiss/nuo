import { describe, expect, test } from "bun:test";
import PostalMime from "postal-mime";
import { deliver, type IncomingMessage } from "../src/index";
import { buildPayload, type MailPayload } from "../src/payload";

const CF_RESULTS = "mx.cloudflare.net; dkim=pass header.d=lumen.example header.s=s1; spf=pass smtp.mailfrom=julie.martin@lumen.example; dmarc=pass header.from=lumen.example";

const RECEIVED = "Received: from mail.lumen.example (mail.lumen.example [203.0.113.24]) by mx.cloudflare.net with ESMTPS; Thu, 26 Nov 2026 08:14:02 +0000";
const FORGED = "Authentication-Results: mx.cloudflare.net; dkim=pass header.d=example.com; dmarc=pass header.from=example.com";

/** The previous hop, Julie's own mail server, added its line before Email Routing added its own on top. */
const SENDER_HOP = "Received: by mail.lumen.example with SMTP id k12; Thu, 26 Nov 2026 00:14:01 -0800";

/** As Email Routing delivers it: its Received line, then its stamps, then the previous hop; a forged verdict sits lower. */
const cloudflare = (results = CF_RESULTS) => [
  RECEIVED,
  "ARC-Seal: i=1; a=rsa-sha256; s=2024; d=email.cloudflare.net; cv=none; b=Kd9",
  "ARC-Message-Signature: i=1; a=rsa-sha256; s=2024; d=email.cloudflare.net; c=relaxed/relaxed; b=Qp2",
  `ARC-Authentication-Results: i=1; ${CF_RESULTS}`,
  "Received-SPF: pass (mx.cloudflare.net: domain of julie.martin@lumen.example designates 203.0.113.24 as permitted sender)",
  ...(results ? [`Authentication-Results: ${results}`] : []),
  "X-CF-Spamh-Score: 1",
];

const mail = (top: string[]) =>
  [
    ...top,
    SENDER_HOP,
    FORGED,
    'From: "Julie Martin" <julie.martin@lumen.example>',
    "To: Work <work@bots.example.com>",
    "Cc: Karim Haddad <karim.haddad@lumen.example>",
    "Subject: Devis cuisine, version 2",
    "Date: Thu, 26 Nov 2026 09:14:00 +0100",
    "Message-ID: <devis-42@lumen.example>",
    "MIME-Version: 1.0",
    'Content-Type: multipart/mixed; boundary="b1"',
    "",
    "--b1",
    "Content-Type: text/plain; charset=utf-8",
    "",
    "Bonjour, voici le devis révisé pour la cuisine.",
    "--b1",
    'Content-Type: application/pdf; name="devis-cuisine-v2.pdf"',
    'Content-Disposition: attachment; filename="devis-cuisine-v2.pdf"',
    "Content-Transfer-Encoding: base64",
    "",
    "JVBERi0xLjcK",
    "--b1--",
    "",
  ].join("\r\n");
const RAW = mail(cloudflare());

const stream = (s: string) => new Response(s).body!;

function message(to = "work@bots.example.com") {
  const m = { rejected: undefined as string | undefined, forwardedTo: undefined as string | undefined };
  const msg: IncomingMessage = {
    to,
    raw: stream(RAW),
    setReject: (reason) => void (m.rejected = reason),
    forward: async (rcpt) => void (m.forwardedTo = rcpt),
  };
  return { msg, m };
}

const ENV = { GATEWAY_URL: "https://hooks.example.com", MAIL_SECRET: "mail-worker-secret-7f3c9a1e5b2d4f60", FALLBACK_FORWARD: "alex@example.com" };

describe("payload", () => {
  test("carries the envelope recipient, the sender, the text and the topmost verdict", async () => {
    const p = buildPayload("work@bots.example.com", await PostalMime.parse(RAW));
    expect(p).toEqual({
      to: "work@bots.example.com",
      from: "julie.martin@lumen.example",
      fromName: "Julie Martin",
      subject: "Devis cuisine, version 2",
      text: "Bonjour, voici le devis révisé pour la cuisine.",
      date: "2026-11-26T08:14:00.000Z",
      messageId: "<devis-42@lumen.example>",
      authResults: CF_RESULTS,
      toHeader: ["work@bots.example.com"],
      cc: ["karim.haddad@lumen.example"],
      attachments: [{ filename: "devis-cuisine-v2.pdf", mimeType: "application/pdf", size: 9 }],
    });
  });
});

describe("verdict", () => {
  test("a verdict the mail brought with it is not passed on", async () => {
    const verdict = async (raw: string) => buildPayload("work@bots.example.com", await PostalMime.parse(raw)).authResults;
    expect(await verdict(mail(cloudflare("")))).toBeUndefined();
    expect(await verdict(mail([]))).toBeUndefined();
    expect(await verdict(mail([`Authentication-Results: ${CF_RESULTS}`, RECEIVED]))).toBeUndefined();
    const noCloudflareVerdict = [...cloudflare(""), FORGED, "X-CF-Spamh-Score: 0"];
    expect(await verdict(mail(noCloudflareVerdict))).toBeUndefined();
  });

  test("sent straight to Cloudflare, a forged verdict after Cloudflare's own is ignored", async () => {
    const raw = [...cloudflare(), FORGED, ...mail([]).split("\r\n").filter((l) => l !== FORGED && l !== SENDER_HOP)].join("\r\n");
    expect(buildPayload("work@bots.example.com", await PostalMime.parse(raw)).authResults).toBe(CF_RESULTS);
  });
});

describe("delivery", () => {
  test("posts the payload with the secret", async () => {
    const calls: { url: string; init: RequestInit }[] = [];
    const { msg, m } = message();
    const r = await deliver(msg, ENV, (async (url: string, init: RequestInit) => {
      calls.push({ url, init });
      return new Response('{"accepted":true}', { status: 202 });
    }) as typeof fetch);
    expect(r).toBe("accepted");
    expect(calls[0]!.url).toBe("https://hooks.example.com/mail");
    expect((calls[0]!.init.headers as Record<string, string>).authorization).toBe(`Bearer ${ENV.MAIL_SECRET}`);
    expect((JSON.parse(String(calls[0]!.init.body)) as MailPayload).subject).toBe("Devis cuisine, version 2");
    expect(m.rejected).toBeUndefined();
  });

  test("bounces only an address the gateway does not know", async () => {
    const unknown = message("compta@bots.example.com");
    expect(await deliver(unknown.msg, ENV, (async () => new Response("{}", { status: 404 })) as unknown as typeof fetch)).toBe("rejected");
    expect(unknown.m.rejected).toBe("Unknown recipient");

    const down = message();
    expect(await deliver(down.msg, ENV, (async () => new Response("", { status: 502 })) as unknown as typeof fetch)).toBe("forwarded");
    expect(down.m.rejected).toBeUndefined();
    expect(down.m.forwardedTo).toBe("alex@example.com");
  });
});
