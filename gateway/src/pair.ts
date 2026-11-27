import { createPairCode, PAIR_CODE_TTL_MS } from "./auth/service";
import { defaultDataDir, openDb } from "./store/db";
import { Store } from "./store/store";

const db = openDb(defaultDataDir());
const store = new Store(db);
const code = createPairCode(store);
const totpReady = !!db.query("SELECT 1 FROM auth_totp WHERE id = 1").get();
db.close();
console.log(`Pairing code for the owner profile (type "owner" in the app's Profil field): ${code.slice(0, 3)} ${code.slice(3)}  (valid ${PAIR_CODE_TTL_MS / 60000} minutes, single use)`);
if (!totpReady) console.warn("2FA is not set up yet: pairing will be refused. Run `bun run src/cli.ts auth-totp-setup` first.");
else console.log("The app also asks for the current code of your authenticator app (or a recovery code).");
