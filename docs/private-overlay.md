# Private overlay

Some files are yours alone: bots with personal instructions, tool servers pointing at your own repositories,
collections for your finances, dashboards. They do not belong in a public fork, yet they must reach your gateway.

The `private/` folder at the root of the repository holds them. Git ignores it. It mirrors the repository tree, and
whatever it holds under `private/gateway/` is laid over `gateway/` when the gateway is deployed:

```
private/
  gateway/
    config/bots.seed.json          replaces gateway/config/bots.seed.json
    config/tools.json              replaces gateway/config/tools.json
    config/dashboards/budget.json  added to the starter dashboards
    src/data/schema/050_finance.sql  extra collections, applied once like the others
```

A file with the same path as a tracked one replaces it; a new path is added. Nothing is ever deleted by the overlay.

- A schema file whose first line is `-- owner-only` is applied to the owner's profile only, not to friends'
  profiles. Migrations are recorded by file name, so deploying with or without the overlay never re-runs one.
- `config/finance-collections.json` (optional) lists the collection ids whose edits need a Face ID step-up
  ([security.md](security.md)). The gateway reads it from its own `config/` folder, so the overlay is enough.
- Scripts you add (for example `scripts/sync/<bank>.ts`, run by a timer or a command task) only exist on hosts
  deployed with the overlay.

Who applies it:

- `scripts/deploy-gateway.sh` stages `gateway/`, copies `private/gateway/` over it, then syncs the result to
  `~/nuo/app` on the host;
- `scripts/install.sh --from-local` does the same (a clone of the public repository has no overlay).

Keep the overlay in its own private git repository if you want history and a backup: `private/` can be a checkout
of it. For new collections, pick schema numbers far from the public ones (`050_` and up) so a future public
migration never takes the same number, and remember that the files you overlay are not reviewed by the public test suite.
