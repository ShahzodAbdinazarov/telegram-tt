#!/usr/bin/env bash
# Svipe Web A (telegram-tt fork) deploy: build for one domain and rsync it to the web host.
#
#   deploy/svipe-deploy.sh dev  [--no-build] [--dry-run]
#   deploy/svipe-deploy.sh prod [--no-build] [--dry-run]
#
# Targets (override with SVIPE_WEBA_DEV / SVIPE_WEBA_PROD, "user@host:/path/"):
#   dev  -> https://web.abdinazarov.uz/a/  (/var/www/tgweb-dev/a/)
#   prod -> https://web.svipe.uz/a/        (/var/www/tgweb/a/)
#
# Why it is shaped like this:
# - Unlike Web K, Web A bakes an absolute BASE_URL (TG_PUBLIC_URL) into the bundle,
#   so every domain needs its own build. BASE_URL is passed via the environment
#   (Vite's loadEnv lets process env win over .env); .env only has to carry
#   TELEGRAM_API_ID=838934 / TELEGRAM_API_HASH (git-ignored).
# - Builds go to build-svipe/<env>/, not dist/: upstream commits its own dist/ in
#   "[Build]" commits, and overwriting it would dirty the tree on every deploy.
# - The session bridge (public/session-bridge.js, loaded first by index.html) is what
#   lets /a and /k share one login; a build without it must never ship.
# - No --delete: open tabs still hold the previous index and lazy-load old hashed
#   chunks; deleting them turns into 404s mid-session. index.html goes up last so
#   no client sees an index whose chunks are not there yet.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV="${1:-}"
shift || true
BUILD=1; DRY=()
for a in "$@"; do
  case "$a" in
    --no-build) BUILD=0 ;;
    --dry-run) DRY=(--dry-run) ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

case "$ENV" in
  dev)
    BASE_URL="https://web.abdinazarov.uz/a/"
    TARGET="${SVIPE_WEBA_DEV:-root@169.58.191.228:/var/www/tgweb-dev/a/}" ;;
  prod)
    BASE_URL="https://web.svipe.uz/a/"
    TARGET="${SVIPE_WEBA_PROD:-root@169.58.191.228:/var/www/tgweb/a/}" ;;
  *) echo "usage: $0 dev|prod [--no-build] [--dry-run]" >&2; exit 2 ;;
esac
API_ID=838934
OUT="build-svipe/$ENV"
SSH_KEY="${SVIPE_SSH_KEY:-$HOME/.ssh/lavha_deploy}"
SSH=(ssh -i "$SSH_KEY" -o BatchMode=yes)
HOST="${TARGET%%:*}"; DIR="${TARGET#*:}"

if [ "$BUILD" = 1 ]; then
  # package.json engines: node ^24.15 || ^26. A local Node 24 lives in ~/.local/node24.
  [ -x "$HOME/.local/node24/bin/node" ] && export PATH="$HOME/.local/node24/bin:$PATH"
  node -e 'const [M,m]=process.versions.node.split(".").map(Number);process.exit(M>=26||(M===24&&m>=15)?0:1)' \
    || { echo "node $(node -v) is too old (need ^24.15 || ^26)" >&2; exit 1; }
  grep -q "^TELEGRAM_API_ID=$API_ID\$" .env 2>/dev/null \
    || { echo ".env must set TELEGRAM_API_ID=$API_ID (and TELEGRAM_API_HASH)" >&2; exit 1; }
  npm ci --no-audit --no-fund
  rm -rf "$OUT"
  BASE_URL="$BASE_URL" npm run build:production -- --outDir "$OUT" --emptyOutDir
fi

# Guards: never ship a build without the Svipe layer or for the wrong domain.
[ -f "$OUT/index.html" ] || { echo "$OUT/index.html missing - run without --no-build" >&2; exit 1; }
grep -q 'session-bridge.js' "$OUT/index.html" || { echo "$OUT/index.html does not load session-bridge.js" >&2; exit 1; }
[ -f "$OUT/session-bridge.js" ] || { echo "$OUT/session-bridge.js missing" >&2; exit 1; }
grep -q "$BASE_URL" "$OUT/index.html" || { echo "$OUT was not built for $BASE_URL" >&2; exit 1; }
grep -rqs --include='*.js' "$API_ID" "$OUT" || { echo "$OUT does not carry API_ID $API_ID" >&2; exit 1; }

"${SSH[@]}" "$HOST" "test -d '$DIR'" || { echo "$TARGET does not exist on the host - check the target" >&2; exit 1; }

RSYNC=(rsync -az ${DRY[@]+"${DRY[@]}"} -e "${SSH[*]}" --exclude='*.map' --exclude='/build-stats.json')
echo "[svipe-deploy] $ENV -> $TARGET (assets)"
"${RSYNC[@]}" --exclude='/index.html' "$OUT/" "$TARGET"
echo "[svipe-deploy] $ENV -> $TARGET (index)"
"${RSYNC[@]}" "$OUT/" "$TARGET"

echo "[svipe-deploy] done: $(git rev-parse --short HEAD) on $ENV ($BASE_URL)"
