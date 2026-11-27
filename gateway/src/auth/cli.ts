import QRCode from "qrcode";
import { defaultLayout } from "../paths";
import { profileLayoutFor } from "../profiles/cli";
import { openDb } from "../store/db";
import { Store } from "../store/store";
import { defaultSecretsFile, loadAuthKey } from "./keys";
import { AuthService } from "./service";

export const AUTH_USAGE = `  Every auth-* command takes --profile <slug> (default: owner).
  bun run src/cli.ts auth-totp-setup [--account <label>]
    Enrols the TOTP second factor: prints an otpauth:// URI, a QR code and 10 single-use recovery codes, once.
    The secret is sealed with NUO_AUTH_KEY (from the environment or ~/.secrets/nuo.env, generated if missing).
  bun run src/cli.ts auth-totp-reset [--account <label>]
    Replaces the TOTP secret and the recovery codes (the old authenticator entry stops working).
  bun run src/cli.ts auth-devices
  bun run src/cli.ts auth-revoke <device id>
  bun run src/cli.ts auth-events [--limit 50]`;

function service(create: boolean, profile?: string) {
  const db = openDb(profile && profile !== "owner" ? profileLayoutFor(profile).data : defaultLayout().data);
  const store = new Store(db);
  const authKey = loadAuthKey({ create });
  return { db, auth: new AuthService(store, { authKey }) };
}

function arg(argv: string[], name: string): string | undefined {
  const i = argv.indexOf(name);
  return i >= 0 ? argv[i + 1] : undefined;
}

export async function authCommand(cmd: string, argv: string[]): Promise<void> {
  const enrol = cmd === "auth-totp-setup" || cmd === "auth-totp-reset";
  const { db, auth } = service(enrol, arg(argv, "--profile"));
  argv = argv.filter((a, i) => a !== "--profile" && argv[i - 1] !== "--profile");
  try {
    if (enrol) {
      if (cmd === "auth-totp-setup" && auth.totpConfigured()) {
        console.error("2FA is already set up. Use `bun run src/cli.ts auth-totp-reset` to replace the secret.");
        process.exitCode = 1;
        return;
      }
      const r = auth.enrollTotp(arg(argv, "--account") || process.env.USER || "owner", cmd === "auth-totp-reset");
      console.log(await QRCode.toString(r.uri, { type: "terminal", small: true, errorCorrectionLevel: "M" }));
      console.log(`Scan the QR code with your authenticator app, or add it by hand:\n  ${r.uri}\n`);
      console.log("Recovery codes (each works once instead of a TOTP code; store them offline, they are not shown again):");
      for (const c of r.recoveryCodes) console.log(`  ${c}`);
      console.log(`\nSecret sealed in nuo.db with NUO_AUTH_KEY (${process.env.NUO_AUTH_KEY ? "environment" : defaultSecretsFile()}).`);
      console.log("Restart the gateway if it was started before the key existed.");
      return;
    }
    switch (cmd) {
      case "auth-devices":
        for (const d of auth.devices()) console.log(`${d.id}  ${d.name}  ${d.platform ?? "-"}  created ${d.createdAt}  seen ${d.lastSeenAt ?? "-"}${d.legacy ? "  (legacy token: must pair again)" : ""}`);
        console.log(`2FA: ${auth.totpConfigured() ? `on, ${auth.recoveryCodesLeft()} recovery codes left` : "not set up"}`);
        return;
      case "auth-revoke":
        if (!argv[0] || !auth.revoke(argv[0], { via: "cli" })) {
          console.error(`unknown device "${argv[0] ?? ""}"`);
          process.exitCode = 1;
        } else console.log(`revoked ${argv[0]}`);
        return;
      case "auth-events":
        for (const e of auth.events(Number(arg(argv, "--limit")) || 50).reverse()) {
          console.log(`${e.at}  ${e.ok ? "ok  " : "FAIL"}  ${e.type.padEnd(20)}  ${e.ip ?? "-"}  ${e.deviceName ?? ""}${e.detail ? `  (${e.detail})` : ""}`);
        }
        return;
    }
  } finally {
    db.close();
  }
}
