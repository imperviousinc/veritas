#!/bin/bash
# Sync the Cargo workspace version into the Xcode project.
# Called by release-plz CI after version bump.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION=$(grep '^version' "$ROOT/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')
PBXPROJ="$ROOT/app/veritas.xcodeproj/project.pbxproj"

if [ -z "$VERSION" ]; then
  echo "Error: could not read version from Cargo.toml"
  exit 1
fi

echo "Syncing version $VERSION into Xcode project..."

# Detect sed flavor (BSD/macOS needs `-i ''`, GNU/Linux needs `-i`)
if sed --version >/dev/null 2>&1; then
  SED_INPLACE=(-i)
else
  SED_INPLACE=(-i '')
fi

# MARKETING_VERSION = semver (e.g. 0.2.0)
sed "${SED_INPLACE[@]}" "s/MARKETING_VERSION = .*/MARKETING_VERSION = ${VERSION};/" "$PBXPROJ"

# CURRENT_PROJECT_VERSION = build number derived from semver
# e.g. 0.2.0 -> 200, 1.3.5 -> 10305
IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD=$((MAJOR * 10000 + MINOR * 100 + ${PATCH:-0}))
sed "${SED_INPLACE[@]}" "s/CURRENT_PROJECT_VERSION = .*/CURRENT_PROJECT_VERSION = ${BUILD};/" "$PBXPROJ"

echo "Done: MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$BUILD"