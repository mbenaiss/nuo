.PHONY: all gateway-check editor-check ios-build mac-test deploy local-setup local-run local-pair

all: gateway-check editor-check ios-build mac-test

gateway-check:
	cd gateway && bun install && bun run typecheck && bun test

# Round-trip tests of the document editor, then its bundle in ios/Nuo/Resources/DocEditor (commit the result).
editor-check:
	cd ios/DocEditor && bun install && bun run typecheck && bun test && bun run build

ios-build:
	cd ios && xcodegen generate && xcodebuild -project Nuo.xcodeproj -scheme Nuo -destination 'generic/platform=iOS Simulator' -quiet build

mac-test:
	cd ios && xcodegen generate && xcodebuild -project Nuo.xcodeproj -scheme NuoMacTests -destination 'platform=macOS' -quiet CODE_SIGNING_ALLOWED=NO test

# NUO_DEPLOY_HOST=user@host make deploy
deploy:
	./scripts/deploy-gateway.sh

# A gateway on this machine, for trying Nuo (docs/getting-started.md). Data and secrets stay in .nuo-local/.
LOCAL_HOME ?= $(CURDIR)/.nuo-local
LOCAL_PORT ?= 8790
LOCAL_HOST ?= 0.0.0.0
LOCAL_ENV = NUO_HOME="$(LOCAL_HOME)" NUO_SECRETS_FILE="$(LOCAL_HOME)/secrets.env" NUO_PORT=$(LOCAL_PORT) NUO_HOST=$(LOCAL_HOST)

local-setup:
	install -d -m 700 "$(LOCAL_HOME)"
	cd gateway && bun install
	cd gateway && $(LOCAL_ENV) bun run src/cli.ts auth-totp-setup --account "Nuo local"

local-run:
	@test -f "$(LOCAL_HOME)/secrets.env" || { echo "run make local-setup first"; exit 1; }
	cd gateway && $(LOCAL_ENV) bun run src/index.ts

local-pair:
	cd gateway && $(LOCAL_ENV) bun run src/pair.ts
