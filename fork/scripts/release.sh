#!/bin/bash
# Build a release from a clean clone of the pushed main branch, publish it on GitHub and add it to
# source.json. Then commit and push source.json.
# Usage: fork/scripts/release.sh ["release notes"]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
REPO="${REPO:-God-Lo/LiveContainer}"
NOTES="${1:-}"
VER=$(git show origin/main:LiveContainer/Info.plist | plutil -extract CFBundleShortVersionString raw -)
# Next build number for this upstream version.
N=$(python3 -c "
import json
v=json.load(open('source.json'))['apps'][0]['versions']
print(1+max([int(x['buildVersion'].split('.')[-1]) for x in v if x['version']=='$VER'] or [0]))")
TAG="$VER.$N"
NOTES="${NOTES:-Based on LiveContainer $VER.}"

# Build in a neutral folder so no local paths end up in the binaries.
WORK=/private/tmp/lcfork-release
rm -rf "$WORK"
git clone -q --branch main "https://github.com/$REPO.git" "$WORK/src"
FORK_BUILD=$N "$WORK/src/fork/scripts/build-ipa.sh"

# Repackage without file metadata, then check for personal info.
mkdir "$WORK/pkg"
( cd "$WORK/pkg" && unzip -q "$WORK/src/fork/out/LiveContainer+SideStore.ipa" )
if grep -rlaE "$HOME|$(id -un)@|$(scutil --get LocalHostName)" "$WORK/pkg/Payload"; then
  echo "The build contains local paths or names; not publishing."; exit 1
fi
IPA="$WORK/LiveContainer+SideStore.ipa"
( cd "$WORK/pkg" && ditto -c -k --norsrc --noextattr --keepParent Payload "$IPA" )

gh release create "$TAG" "$IPA" --repo "$REPO" --title "$TAG" --notes "$NOTES"

python3 - "$IPA" "$REPO" "$VER" "$TAG" "$NOTES" <<'PY'
import json, os, sys, datetime
ipa, repo, ver, tag, notes = sys.argv[1:]
src = json.load(open("source.json"))
src["apps"][0]["versions"].insert(0, {
    "version": ver, "buildVersion": tag,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": notes,
    "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/LiveContainer+SideStore.ipa",
    "size": os.path.getsize(ipa), "minOSVersion": "15.0"})
with open("source.json", "w") as f:
    json.dump(src, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY
rm -rf "$WORK"
echo "Released $TAG. Commit and push source.json."
