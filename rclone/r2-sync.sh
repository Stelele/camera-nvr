#!/bin/sh
# Archive Frigate recordings and event exports to Cloudflare R2.
#
# ── WHY `copy` AND NOT `sync` ────────────────────────────────────────────────
# Frigate keeps only a short rolling window on local disk (LOCAL_RETENTION_DAYS,
# default 2). `rclone sync` makes the destination match the source EXACTLY —
# including deleting anything in the bucket that is no longer on disk. Run that
# against a rolling source and it will quietly erase your entire archive every
# time local retention lapses.
#
# `rclone copy` only adds and updates. It never deletes. That is what an archive
# wants. Expiry is handled by an R2 lifecycle policy on the bucket instead
# (see README "Retention").
#
# Idempotent: files already in the bucket with matching size and mtime are
# skipped, so re-running is cheap and safe.
#
# Credentials come from the R2_* environment variables (see .env.example); the
# rclone config file is generated at run time, not committed.

set -eu

BUCKET="${R2_BUCKET:-camera-archive}"
REMOTE="r2:${BUCKET}"
LOCAL="/media/frigate"

# ── Credentials ──────────────────────────────────────────────────────────────
# rclone is pointed at this file explicitly. Without it rclone falls back to
# /config/rclone/rclone.conf with no `r2` remote defined, so every command fails
# with a confusing "didn't find section in config file" instead of a real error.
# The path is exported once here rather than passed on each call.
RCLONE_CONFIG="${RCLONE_CONFIG:-/config/rclone/rclone.conf}"
mkdir -p "$(dirname "$RCLONE_CONFIG")"
export RCLONE_CONFIG

# Build the config from the environment rather than shipping a hand-edited
# rclone.conf, so .env stays the single source of truth for secrets.
write_config() {
  endpoint="${R2_ENDPOINT:-https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com}"
  umask 077
  cat >"$RCLONE_CONFIG" <<EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = ${R2_ACCESS_KEY_ID}
secret_access_key = ${R2_SECRET_ACCESS_KEY}
endpoint = ${endpoint}
acl = private
EOF
}

# R2 does not implement the streaming chunked payload the AWS SDK negotiates by
# default (STREAMING-AWS4-HMAC-SHA256-PAYLOAD). rclone is not the AWS SDK and
# does not negotiate it, so no DisablePayloadSigning equivalent is needed here —
# this is exactly why rclone is the right tool and the AWS SDK was not.
# See njeremoto-operations/backend/Infrastructure/Storage/R2ObjectStorage.cs.

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

if [ -z "${R2_ACCOUNT_ID:-}" ] || [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ]; then
  log "ERROR: R2_ACCOUNT_ID / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY are unset."
  log "       Fill them in .env (see .env.example) and retry."
  exit 1
fi

if [ ! -d "$LOCAL" ]; then
  log "ERROR: $LOCAL not found — is Frigate writing recordings?"
  exit 1
fi

write_config

# Fail fast and loudly on bad credentials rather than silently archiving nothing.
if ! rclone lsd "$REMOTE:" >/dev/null 2>&1; then
  log "ERROR: cannot reach $REMOTE — check R2_* credentials in .env"
  exit 1
fi

# 1. Continuous recordings
if [ -d "$LOCAL/record" ]; then
  log "archiving recordings -> ${REMOTE}/record"
  rclone copy "$LOCAL/record" "${REMOTE}/record" \
    --fast-list \
    --transfers 4 \
    --checkers 8 \
    --s3-no-head \
    --stats 30s --stats-one-line \
    --log-level INFO
else
  log "no ${LOCAL}/record directory yet, skipping"
fi

# 2. Event exports (clips Frigate cuts on person detection)
if [ -d "$LOCAL/exports" ]; then
  log "archiving event exports -> ${REMOTE}/events"
  rclone copy "$LOCAL/exports" "${REMOTE}/events" \
    --fast-list \
    --transfers 4 \
    --checkers 8 \
    --s3-no-head \
    --stats 30s --stats-one-line \
    --log-level INFO
else
  log "no ${LOCAL}/exports directory yet, skipping"
fi

log "archive pass complete"

# Suggested bucket-level lifecycle (set in the Cloudflare dashboard, not here):
#   expire objects under prefix "record/" after 90 days
#   expire objects under prefix "events/" after 365 days