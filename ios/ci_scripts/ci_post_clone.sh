#!/bin/sh
set -e

if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

cd "$CI_PRIMARY_REPOSITORY_PATH/ios"

# Local.xcconfig is not in the repository: the workflow's environment variables give the signing identity.
if [ -n "$NUO_BUNDLE_ID" ]; then
  {
    echo "DEVELOPMENT_TEAM = ${NUO_DEVELOPMENT_TEAM}"
    echo "NUO_BUNDLE_ID = ${NUO_BUNDLE_ID}"
    echo "NUO_APP_GROUP = ${NUO_APP_GROUP:-group.${NUO_BUNDLE_ID}}"
  } > Local.xcconfig
fi

xcodegen generate
