#!/bin/sh
# fetch.sh URL [OUTPUT]: downloads a file. GitHub release links (github.com/<owner>/<repo>/releases/
# download/<tag>/<name>) sometimes time out while GitHub's API still serves the same file, so those
# fall back to the API, without signing in.
url="$1"
out="${2:-$(basename "$url")}"
curl -fsSL -o "$out" "$url" && exit 0
case "$url" in
  https://github.com/*/releases/download/*)
    repo=$(echo "$url" | cut -d/ -f4-5)
    tag=$(echo "$url" | cut -d/ -f8)
    name=$(echo "$url" | cut -d/ -f9)
    asset=$(curl -fsSL "https://api.github.com/repos/$repo/releases/tags/$tag" |
      python3 -c "import json,sys; print(next(a['url'] for a in json.load(sys.stdin)['assets'] if a['name']==sys.argv[1]))" "$name") || exit 1
    echo "fetch.sh: $url failed; using GitHub's API" >&2
    curl -fsSL -H "Accept: application/octet-stream" -o "$out" "$asset"
    ;;
  *) exit 1 ;;
esac
