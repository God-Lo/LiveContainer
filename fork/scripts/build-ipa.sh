#!/bin/bash
# Build LiveContainer+SideStore.ipa from this fork, the same way upstream's CI does. Install it with
# iloader; it keeps the upstream bundle ID, so it replaces your existing LiveContainer and keeps its
# data. The IPA contains no apps' Shortcuts actions: LiveContainer adds those itself on the phone when
# you install apps (see README.md).
#
# Output: fork/out/LiveContainer+SideStore.ipa (and LiveContainer.ipa without SideStore). Build files are
# removed afterwards; on failure the logs stay in fork/out for inspection.
#
# FORK_BUILD=N sets the build number to <upstream version>.N, so SideStore sees each fork release as an update.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/fork/out"
WORK="$OUT/work"

rm -rf "$WORK" && mkdir -p "$WORK/bin"
command -v ldid >/dev/null || brew install ldid
# upstream's packaging script downloads with wget
if ! command -v wget >/dev/null; then
  printf '#!/bin/sh\nexec curl -fL -o "$(basename "$1")" "$1"\n' > "$WORK/bin/wget"; chmod +x "$WORK/bin/wget"
fi
export PATH="$WORK/bin:$PATH"

echo "==> Building (unsigned Release archive)"
git -C "$ROOT" submodule update --init --recursive
xcodebuild archive -project "$ROOT/LiveContainer.xcodeproj" -scheme LiveContainer -sdk iphoneos -arch arm64 \
  -configuration Release -archivePath "$WORK/archive" -derivedDataPath "$OUT/DerivedData" \
  CODE_SIGNING_ALLOWED=NO > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "Build failed; see $OUT/build.log"; exit 1; }

APP="$WORK/archive.xcarchive/Products/Applications/LiveContainer.app"
if [ -n "${FORK_BUILD:-}" ]; then
  VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Info.plist")
  for plist in "$APP/Info.plist" "$APP"/PlugIns/*.appex/Info.plist; do
    /usr/libexec/PlistBuddy -c "Set CFBundleVersion $VER.$FORK_BUILD" "$plist"
  done
  echo "==> Build number $VER.$FORK_BUILD"
fi

# Apps' widget extensions can show Live Activities through LiveContainer's widget extension.
/usr/libexec/PlistBuddy -c "Add :NSSupportsLiveActivities bool true" "$APP/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :NSSupportsLiveActivities true" "$APP/Info.plist"

# Sign the app and its extensions with their entitlements, the same as upstream's CI (placeholder team
# AAAAA11111). SideStore takes app groups from these; without them LiveContainer loses its app group.
echo "==> Signing with entitlements"
sign() {  # sign <binary> <entitlements file> <bundle id>
  sed -e 's/\$(AppIdentifierPrefix)/AAAAA11111./g' -e 's/\$(DEVELOPMENT_TEAM)/AAAAA11111/g' \
      -e "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/$3/g" \
      -e 's/\$(APP_GROUP_SIDESTORE)/group.com.SideStore.SideStore/g' \
      -e 's/\$(APP_GROUP_ALTSTORE)/group.com.rileytestut.AltStore/g' "$2" > "$WORK/ent.plist"
  ldid -S"$WORK/ent.plist" "$1"
}
bid() { /usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$1/Info.plist"; }
exe() { echo "$1/$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$1/Info.plist")"; }
sign "$(exe "$APP")" "$ROOT/entitlements.xml" "$(bid "$APP")"
for appex in "$APP"/PlugIns/*.appex; do
  name=$(basename "$appex" .appex)
  ent="$ROOT/$name/$name.entitlements"
  if [ -f "$ROOT/fork/Extensions/$name/$name.entitlements" ]; then
    ent="$ROOT/fork/Extensions/$name/$name.entitlements"
    # The fork's extensions must not need anything SideStore would register with your Apple ID.
    keys=$(plutil -convert json -o - "$ent" | python3 -c 'import json,sys; print(" ".join(sorted(json.load(sys.stdin))))')
    [ "$keys" = "com.apple.security.application-groups" ] || { echo "$name asks for more than app groups: $keys"; exit 1; }
  fi
  [ -f "$ent" ] || { echo "No entitlements for $name"; exit 1; }
  sign "$(exe "$appex")" "$ent" "$(bid "$appex")"
done
grep -q "group.com.SideStore.SideStore" < <(ldid -e "$(exe "$APP")") || { echo "Signing failed: no app group"; exit 1; }

echo "==> Packaging with upstream's .github/build_github.sh"
ln -s "$ROOT/.github" "$WORK/.github"
( cd "$WORK" && scheme=LiveContainer archive_path=archive sh .github/build_github.sh > "$OUT/package.log" 2>&1 ) \
  || { tail -30 "$OUT/package.log"; exit 1; }

cp "$WORK/LiveContainer+SideStore.ipa" "$WORK/LiveContainer.ipa" "$OUT/"
# Leave only the IPAs behind (logs are kept only when a step fails).
rm -rf "$WORK" "$OUT/DerivedData" "$OUT/build.log" "$OUT/package.log"
echo "Done: $OUT/LiveContainer+SideStore.ipa"
