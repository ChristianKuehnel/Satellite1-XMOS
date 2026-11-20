#!/usr/bin/env bash

# Publish a Satellite1 firmware dev build to GitHub Releases.
#
# Produces/updates three things (all via the GitHub REST API, no third-party
# actions so behaviour is fully deterministic):
#
#   1. An IMMUTABLE, per-push pre-release tagged:
#        dev-YYYYMMDD-<shortsha>
#      If that tag already exists the pinned release is reused as-is (it is never
#      overwritten), so each push keeps a permanent, addressable artifact.
#
#   2. A ROLLING pre-release tagged:
#        dev-latest
#      Its tag is moved to the newest commit and its assets are replaced, so it
#      always points at the freshest development build.
#
#   3. A releases.json index published to the GitHub Pages branch (an orphan
#      branch) describing dev-latest plus the most recent pinned builds.
#
# Required environment:
#   GITHUB_REPOSITORY       owner/repo
#   GITHUB_TOKEN            token with `contents: write`
#   DEV_BUILD_COMMIT        full commit sha of the build
#   DEV_BUILD_VERSION       semver string, e.g. v0.0.0-dev
#   DEV_BUILD_GIT_DESCRIBE  raw `git describe --always --dirty` output
#   DEV_BUILD_TAG           pinned tag, e.g. dev-20261115-c332377
#   DEV_LATEST_TAG          rolling tag (default: dev-latest)
#   DEV_BUILD_DATE          ISO-8601 UTC build timestamp
#   DEV_BUILD_BRANCH        source branch name
#   ASSETS_DIR              directory containing the .bin, .sha256 and .md5 assets
#
# Optional environment:
#   GH_PAGES_BRANCH         default: gh-pages
#   MAX_INDEX_ENTRIES       default: 100

set -euo pipefail

# ---------------------------------------------------------------------------
# Required inputs
# ---------------------------------------------------------------------------
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
COMMIT="${DEV_BUILD_COMMIT:?DEV_BUILD_COMMIT is required}"
VERSION="${DEV_BUILD_VERSION:?DEV_BUILD_VERSION is required}"
DESCRIBE="${DEV_BUILD_GIT_DESCRIBE:?DEV_BUILD_GIT_DESCRIBE is required}"
PINNED_TAG="${DEV_BUILD_TAG:?DEV_BUILD_TAG is required}"
LATEST_TAG="${DEV_LATEST_TAG:-dev-latest}"
BUILD_DATE="${DEV_BUILD_DATE:?DEV_BUILD_DATE is required}"
BRANCH="${DEV_BUILD_BRANCH:-develop}"
ASSETS_DIR="${ASSETS_DIR:?ASSETS_DIR is required}"

PAGES_BRANCH="${GH_PAGES_BRANCH:-gh-pages}"
MAX_ENTRIES="${MAX_INDEX_ENTRIES:-100}"

API="https://api.github.com"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
urlencode() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# api METHOD PATH [JSON_BODY]  -> prints response body
# PATH is either a repo-relative path (e.g. /releases) or an absolute URL
# (e.g. the `url` field the API returns for a release asset).
api() {
    local method="$1" path="$2" body="${3-}"
    local url
    case "$path" in
        http*) url="$path" ;;
        *)     url="$API/repos/$REPO$path" ;;
    esac
    local -a args=(-sS -X "$method"
        -H "Authorization: Bearer $TOKEN"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28")
    if [ -n "$body" ]; then
        args+=(--data "$body")
    fi
    curl "${args[@]}" "$url"
}

# http_code METHOD PATH [JSON_BODY] -> prints HTTP status code
http_code() {
    local method="$1" path="$2" body="${3-}"
    local url
    case "$path" in
        http*) url="$path" ;;
        *)     url="$API/repos/$REPO$path" ;;
    esac
    local -a args=(-sS -o /dev/null -w "%{http_code}" -X "$method"
        -H "Authorization: Bearer $TOKEN"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28")
    if [ -n "$body" ]; then
        args+=(--data "$body")
    fi
    curl "${args[@]}" "$url"
}

# release_exists TAG -> exit 0 if a release for this tag exists
release_exists() {
    [ "$(http_code GET "/releases/tags/$1")" = "200" ]
}

# release_id_for_tag TAG -> prints numeric release id (empty if absent)
release_id_for_tag() {
    api GET "/releases/tags/$1" 2>/dev/null | jq -r '.id // empty'
}

# create_release TAG NAME BODY COMMIT -> prints new release id (exits non-zero on failure)
create_release() {
    local tag="$1" name="$2" body="$3" commit="$4"
    local payload raw id
    payload=$(jq -n \
        --arg tag "$tag" --arg name "$name" --arg body "$body" --arg commit "$commit" \
        '{tag_name:$tag, name:$name, body:$body, prerelease:true, make_latest:"false", target_commitish:$commit, draft:false}')
    raw="$(api POST /releases "$payload")"
    id="$(printf '%s' "$raw" | jq -r '.id // empty')"
    if [ -z "$id" ]; then
        echo "ERROR: failed to create release '$tag'. API response:" >&2
        printf '%s\n' "$raw" >&2
        return 1
    fi
    printf '%s' "$id"
}

# upload_asset RELEASE_ID NAME FILE
upload_asset() {
    local release_id="$1" name="$2" file="$3"
    local resp
    resp="$(curl -sS -X POST \
        -H "Authorization: Bearer $TOKEN" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/octet-stream" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        --data-binary "@$file" \
        "https://uploads.github.com/repos/$REPO/releases/$release_id/assets?name=$(urlencode "$name")")"
    if ! printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
        echo "ERROR: failed to upload asset '$name' to release $release_id. API response:" >&2
        printf '%s\n' "$resp" >&2
        return 1
    fi
    echo "    uploaded: $name"
}

# publish_assets_to_release RELEASE_ID  -> uploads every .bin, .sha256 and .md5 in ASSETS_DIR
publish_assets_to_release() {
    local release_id="$1"
    local f base
    for f in "$ASSETS_DIR"/*; do
        [ -f "$f" ] || continue
        base="$(basename "$f")"
        case "$base" in
            *.bin|*.sha256|*.md5)
                upload_asset "$release_id" "$base" "$f"
                ;;
        esac
    done
}

# delete_release_assets RELEASE_ID -> removes all existing assets (loud on failure)
#
# The per-asset DELETE must target each asset's own canonical URL (the `url`
# field the API returns, e.g. .../releases/assets/<id>). The
# releases/<release_id>/assets/<id> form 404s for these assets, which previously
# left stale assets behind and made the next upload fail with `already_exists`.
delete_release_assets() {
    local release_id="$1"
    local rows name url code
    rows="$(api GET "/releases/$release_id/assets?per_page=100" | jq -r '.[] | "\(.name)\t\(.url)"')"
    while IFS=$'\t' read -r name url; do
        [ -n "$url" ] || continue
        code="$(http_code DELETE "$url" || true)"
        if [ "$code" != "204" ]; then
            echo "ERROR: failed to delete asset '$name' (HTTP $code)" >&2
            return 1
        fi
        echo "    deleted: $name"
    done <<< "$rows"
}

RELEASE_BODY="$(cat <<EOF
Development build of \`${BRANCH}\` (unreleased) - **${VERSION}**

| Field | Value |
| ----- | ----- |
| Commit | \`${COMMIT}\` |
| git describe | \`${DESCRIBE}\` |
| Branch | \`${BRANCH}\` |
| Built (UTC) | ${BUILD_DATE} |

Automatically generated by the dev-build workflow. This is an unsigned development
artifact - validate the \`.sha256\` checksums before use.
EOF
)"

# ---------------------------------------------------------------------------
# 1) Immutable per-push pre-release
# ---------------------------------------------------------------------------
if release_exists "$PINNED_TAG"; then
    echo ">> Pinned release '$PINNED_TAG' already exists; reusing it (not overwritten)."
    PINNED_ID="$(release_id_for_tag "$PINNED_TAG")"
else
    echo ">> Creating pinned pre-release '$PINNED_TAG' at $COMMIT"
    PINNED_ID="$(create_release "$PINNED_TAG" "Development build $PINNED_TAG" "$RELEASE_BODY" "$COMMIT")"
    publish_assets_to_release "$PINNED_ID"
fi
PINNED_URL="$(api GET "/releases/tags/$PINNED_TAG" | jq -r '.html_url')"
echo ">> Pinned release: $PINNED_URL"

# ---------------------------------------------------------------------------
# 2) Rolling dev-latest pre-release
# ---------------------------------------------------------------------------
echo ">> Moving tag '$LATEST_TAG' to $COMMIT"
api PUT "/git/refs/tags/$LATEST_TAG" \
    "$(jq -n --arg ref "refs/tags/$LATEST_TAG" --arg sha "$COMMIT" '{ref:$ref, sha:$sha}')" >/dev/null

if release_exists "$LATEST_TAG"; then
    LATEST_ID="$(release_id_for_tag "$LATEST_TAG")"
    echo ">> Replacing assets on rolling release '$LATEST_TAG' (id $LATEST_ID)"
    delete_release_assets "$LATEST_ID"
else
    echo ">> Creating rolling release '$LATEST_TAG' at $COMMIT"
    LATEST_ID="$(create_release "$LATEST_TAG" "Development build (latest)" "$RELEASE_BODY" "$COMMIT")"
fi
publish_assets_to_release "$LATEST_ID"
LATEST_URL="$(api GET "/releases/tags/$LATEST_TAG" | jq -r '.html_url')"
echo ">> Rolling release: $LATEST_URL"

# ---------------------------------------------------------------------------
# 3) releases.json index on the GitHub Pages branch (orphan)
# ---------------------------------------------------------------------------
echo ">> Updating '$PAGES_BRANCH/releases.json'"

# Fetch the existing index (may not exist yet).
EXISTING='{}'
if [ "$(http_code GET "/contents/releases.json?ref=$PAGES_BRANCH")" = "200" ]; then
    EXISTING="$(api GET "/contents/releases.json?ref=$PAGES_BRANCH" | jq -r '.content' | base64 -d)"
fi
# Sanitize to guaranteed-valid JSON object.
EXISTING="$(jq -c . <<<"$EXISTING" 2>/dev/null || echo '{}')"

NEW_JSON="$(jq -n \
    --argjson existing "$EXISTING" \
    --arg tag "$PINNED_TAG" \
    --arg commit "$COMMIT" \
    --arg version "$VERSION" \
    --arg describe "$DESCRIBE" \
    --arg date "$BUILD_DATE" \
    --arg url "$PINNED_URL" \
    --arg latest_tag "$LATEST_TAG" \
    --arg latest_url "$LATEST_URL" \
    --argjson max "$MAX_ENTRIES" \
    '
    ($existing.releases // []) as $rels
    | {
        dev_latest: {
          tag: $latest_tag,
          url: $latest_url,
          commit: $commit,
          version: $version,
          git_describe: $describe,
          date: $date
        },
        releases: (
          ( ( $rels | map(select(.tag != $tag)) )
            + [ {tag:$tag, url:$url, commit:$commit, version:$version, git_describe:$describe, date:$date} ] )
          | sort_by(.date) | reverse | .[0:$max]
        )
      }
    ')"

B64="$(printf '%s' "$NEW_JSON" | base64 -w0)"
BLOB_ID="$(api POST /git/blobs "$(jq -n --arg c "$B64" '{content:$c, encoding:"base64"}')" | jq -r '.sha // empty')"
[ -n "$BLOB_ID" ] || { echo "ERROR: failed to create git blob for index"; exit 1; }
TREE_ID="$(api POST /git/trees "$(jq -n --arg s "$BLOB_ID" '{tree:[{path:"releases.json",mode:"100644",type:"blob",sha:$s}]}')" | jq -r '.sha // empty')"
[ -n "$TREE_ID" ] || { echo "ERROR: failed to create git tree for index"; exit 1; }
COMMIT_ID="$(api POST /git/commits "$(jq -n --arg t "$TREE_ID" --arg msg "Update dev releases index ($PINNED_TAG)" '{message:$msg, tree:$t}')" | jq -r '.sha // empty')"
[ -n "$COMMIT_ID" ] || { echo "ERROR: failed to create git commit for index"; exit 1; }

# PUT /git/refs/heads/<branch> only works when the ref already exists (it 422s
# otherwise); creating a brand-new branch must use POST /git/refs.
if [ "$(http_code GET "/git/refs/heads/$PAGES_BRANCH")" = "200" ]; then
    echo ">> Updating existing '$PAGES_BRANCH' branch ref"
    REF_RESP="$(api PUT "/git/refs/heads/$PAGES_BRANCH" "$(jq -n --arg sha "$COMMIT_ID" --argjson force true '{sha:$sha, force:$force}')" | cat)"
else
    echo ">> Creating new '$PAGES_BRANCH' branch at $COMMIT_ID"
    REF_RESP="$(api POST /git/refs "$(jq -n --arg ref "refs/heads/$PAGES_BRANCH" --arg sha "$COMMIT_ID" '{ref:$ref, sha:$sha}')" | cat)"
fi
echo "    ref response: $(jq -c '{ref:(.ref // "null"), sha:(.object.sha // "null")}' <<<"$REF_RESP" 2>/dev/null)"
[ "$(jq -r '.ref // empty' <<<"$REF_RESP" 2>/dev/null)" = "refs/heads/$PAGES_BRANCH" ] \
    || { echo "ERROR: failed to set '$PAGES_BRANCH' branch ref"; exit 1; }

echo ">> Index published to https://raw.githubusercontent.com/$REPO/heads/$PAGES_BRANCH/releases.json"
echo ">> Done."
