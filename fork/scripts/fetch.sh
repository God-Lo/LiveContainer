#!/bin/sh
# fetch.sh URL [OUTPUT]: downloads a file. GitHub release links (github.com/<owner>/<repo>/releases/
# download/<tag>/<name>) sometimes time out for users who aren't signed in, so those fall back to
# GitHub's API, then (with FETCH_SIGNED_IN=1) to the GitHub CLI's signed-in download.
url="$1"
out="${2:-$(basename "$url")}"
curl -fsSL -o "$out" "$url" && exit 0
case "$url" in
  https://github.com/*/releases/download/*)
    repo=$(echo "$url" | cut -d/ -f4-5)
    tag=$(echo "$url" | cut -d/ -f8)
    name=$(echo "$url" | cut -d/ -f9)
    asset=$(curl -fsSL "https://api.github.com/repos/$repo/releases/tags/$tag" |
      python3 -c "import json,sys; print(next(a['url'] for a in json.load(sys.stdin)['assets'] if a['name']==sys.argv[1]))" "$name")
    if [ -n "$asset" ]; then
      echo "fetch.sh: $url failed; using GitHub's API" >&2
      curl -fsSL -H "Accept: application/octet-stream" -o "$out" "$asset" && exit 0
    fi
    [ "${FETCH_SIGNED_IN:-}" = 1 ] && command -v gh >/dev/null || exit 1
    echo "fetch.sh: using the GitHub CLI's signed-in download" >&2
    tmp=$(mktemp -d) && gh release download "$tag" --repo "$repo" --pattern "$name" --dir "$tmp" && mv "$tmp/$name" "$out"
    ;;
  *) exit 1 ;;
esac
