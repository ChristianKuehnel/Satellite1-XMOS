#!/usr/bin/env bash

# Retention/cleanup for Satellite1 firmware dev-build releases.
#
# Deletes pinned `dev-*` pre-releases older than RETENTION_DAYS. It NEVER
# touches:
#   - the rolling `dev-latest` release,
#   - any non-pre-release (real) releases,
#   - tags that do not match the `dev-*` scheme.
#
# Environment:
#   GITHUB_REPOSITORY   owner/repo
#   GITHUB_TOKEN        token with `contents: write`
#   RETENTION_DAYS      default: 180
#   DRY_RUN             "1" to only report what would be deleted (no writes)

set -euo pipefail

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
TOKEN="${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
RETENTION_DAYS="${RETENTION_DAYS:-180}"
DRY_RUN="${DRY_RUN:-0}"

API="https://api.github.com"
NOW_EPOCH="$(date -u +%s)"
CUTOFF_EPOCH=$(( NOW_EPOCH - RETENTION_DAYS * 86400 ))

api() {
    local method="$1" path="$2" body="${3-}"
    local -a args=(-sS -X "$method"
        -H "Authorization: Bearer $TOKEN"
        -H "Accept: application/vnd.github+json"
        -H "X-GitHub-Api-Version: 2022-11-28")
    if [ -n "$body" ]; then
        args+=(--data "$body")
    fi
    curl "${args[@]}" "$API/$REPO$path"
}

echo ">> Dev-release cleanup: retention=${RETENTION_DAYS}d, cutoff_epoch=${CUTOFF_EPOCH}, dry_run=${DRY_RUN}"

deleted=0
kept=0
page=1

while :; do
    resp="$(api GET "/releases?per_page=100&page=$page")"
    count="$(jq 'length' <<<"$resp")"
    [ "$count" = "0" ] && break

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        tag="$(jq -r '.tag_name' <<<"$entry")"
        id="$(jq -r '.id' <<<"$entry")"
        pre="$(jq -r '.prerelease' <<<"$entry")"
        published="$(jq -r '.published_at' <<<"$entry")"

        # Only ever consider the dev-* scheme.
        case "$tag" in
            dev-*) : ;;
            *) kept=$((kept + 1)); continue ;;
        esac

        # Never touch the rolling release.
        if [ "$tag" = "dev-latest" ]; then
            kept=$((kept + 1)); continue
        fi

        # Only prune real pre-releases.
        if [ "$pre" != "true" ]; then
            kept=$((kept + 1)); continue
        fi

        pub_epoch="$(date -u -d "$published" +%s 2>/dev/null || echo 0)"
        if [ "$pub_epoch" -ge "$CUTOFF_EPOCH" ]; then
            kept=$((kept + 1)); continue
        fi

        echo "  expired: '$tag' (id $id, published $published)"
        if [ "$DRY_RUN" != "1" ]; then
            api DELETE "/releases/$id" >/dev/null
        fi
        deleted=$((deleted + 1))
    done < <(jq -c '.[]' <<<"$resp")

    [ "$count" -lt 100 ] && break
    page=$((page + 1))
done

echo ">> Cleanup complete: deleted=${deleted} kept=${kept} (dry_run=${DRY_RUN})"
