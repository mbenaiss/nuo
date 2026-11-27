import { HttpError } from "../bots/service";
import { MuscuInputError, PHOTO_PREFIX, type Muscu } from "./service";

type Ctx = { req: Request; params: string[]; url: URL };
export type MuscuRoute = [string, RegExp, (ctx: Ctx) => unknown];

const PHOTO_ROUTE = new RegExp(`^${PHOTO_PREFIX.replace(/\//g, "\\/")}(.+)$`);

/** Paired app: the Muscu screen. */
export function muscuRoutes(m: Muscu): MuscuRoute[] {
  return [
    ["GET", /^\/api\/muscu$/, () => m.list()],
    [
      "GET",
      PHOTO_ROUTE,
      ({ params }) => {
        const file = m.photo(params[0]!);
        if (!file) throw new HttpError(404, "photo introuvable");
        // The photos change only with the fitness repo: a day in the app's URL cache spares the gym's network.
        return new Response(Bun.file(file), { headers: { "content-type": "image/jpeg", "cache-control": "private, max-age=86400" } });
      },
    ],
    [
      "POST",
      /^\/api\/muscu\/sessions$/,
      async ({ req }) => {
        let body: unknown;
        try {
          body = await req.json();
        } catch {
          throw new HttpError(400, "invalid JSON body");
        }
        try {
          return m.finish(body);
        } catch (e) {
          if (e instanceof MuscuInputError) throw new HttpError(400, e.message);
          throw e;
        }
      },
    ],
  ];
}
