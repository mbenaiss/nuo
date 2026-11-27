# Contributing to Nuo

Thanks for your interest. Bug reports, fixes, documentation and new features are all welcome. For anything larger
than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Setup

| Part | Needs |
|---|---|
| gateway (`gateway/`) | [Bun](https://bun.sh) 1.4.2 or newer |
| document editor (`ios/DocEditor/`) | Bun |
| apps (`ios/`) | macOS, Xcode 26 or newer, [XcodeGen](https://github.com/yonaskolb/XcodeGen) |

[docs/getting-started.md](docs/getting-started.md) shows how to run the apps in demo mode and a gateway on your
computer. `ios/Nuo.xcodeproj` is generated from `ios/project.yml`: edit the YAML, then `xcodegen generate`.

## Checks

```sh
make                 # everything below
make gateway-check   # gateway: bun install, typecheck, tests
make editor-check    # document editor: typecheck, tests, bundle into ios/Nuo/Resources/DocEditor
make ios-build       # iPhone app for the simulator
make mac-test        # Mac unit tests
```

Run the checks of the parts you touched before opening a pull request. GitHub Actions runs the gateway and editor
checks; the apps build on Xcode Cloud. When you change the document editor, commit the rebuilt bundle with it: CI
fails if the bundle does not match the sources.

## Guidelines

- **Tests.** Add or update the tests that cover your change: `bun test` in `gateway/test/`, XCTest in
  `ios/MacTests/`. Use realistic test data from the domain (a client "Julie Martin", an order `ORD-2026-104857`)
  rather than placeholders, so the intent of each test reads at a glance.
- **Protocol.** `gateway/src/protocol.ts` and `ios/Nuo/Network/Protocol.swift` mirror each other; change both,
  and [docs/protocol.md](docs/protocol.md) with them.
- **Style.** Follow the code around you. TypeScript is strict; Swift uses Swift 6 strict concurrency. Comments
  explain a non-obvious why, never what the code does.
- **Scope.** One topic per pull request. Mention a nearby bug you noticed in the description rather than fixing it
  in the same change.
- **Secrets.** Never commit a secret, a real address or personal data. Settings go in the gateway's env file
  ([deploy/nuo.env.example](deploy/nuo.env.example)), Apple signing in `ios/Local.xcconfig`, and anything
  personal in your [private overlay](docs/private-overlay.md).
- **Docs.** Update the page under `docs/` that describes the behavior you change.

## Commits and pull requests

Short, imperative commit messages (`fix: Keep the pairing code valid after a restart`). Describe in the pull request
what changes for the user, how you tested it, and include screenshots for visible changes in the apps.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
