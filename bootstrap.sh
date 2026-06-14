#!/usr/bin/env bash
set -euo pipefail

# ===================================================================
# bootstrap.sh — Lee's Feeds security patch bootstrapper
#
# Applies the three high-ROI fixes from the security review on top of
# an existing ~/leesfeeds deployment (as produced by setup.sh):
#
#   FIX 1 — Stored XSS via javascript:/data: links in feed items
#            (backend sanitiser + frontend safeHref guard)
#   FIX 2 — feedparser hang protection (global socket timeout)
#   FIX 3 — XML DoS protection (defusedxml + recursion cap on OPML import)
#
# Plus two trivial cleanups:
#   - remove unused 'requests' dependency, bump feedparser, add defusedxml
#   - fix scripts/prune_db.sh to resolve its own path (works under cron)
#
# Usage:
#   ./bootstrap.sh                # patch ~/leesfeeds
#   ./bootstrap.sh /path/to/proj  # patch a specific project dir
#   ./bootstrap.sh --dry-run      # show what would change, do nothing
#
# Idempotent: safe to re-run. Each patch checks for its own marker
# comment before applying.
# ===================================================================

DRY_RUN=0
PROJECT_DIR="${HOME}/leesfeeds"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) PROJECT_DIR="$arg" ;;
  esac
done

MAIN_PY="${PROJECT_DIR}/app/main.py"
INDEX_HTML="${PROJECT_DIR}/app/static/index.html"
REQUIREMENTS="${PROJECT_DIR}/requirements.txt"
PRUNE_SH="${PROJECT_DIR}/scripts/prune_db.sh"

log()  { echo "[bootstrap] $*"; }
fail() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

[ -d "${PROJECT_DIR}" ] || fail "Project directory not found: ${PROJECT_DIR}
Run setup.sh first, or pass the correct path: ./bootstrap.sh /path/to/leesfeeds"

[ -f "${MAIN_PY}" ]      || fail "Missing ${MAIN_PY}"
[ -f "${INDEX_HTML}" ]   || fail "Missing ${INDEX_HTML}"
[ -f "${REQUIREMENTS}" ] || fail "Missing ${REQUIREMENTS}"

log "Project: ${PROJECT_DIR}"
[ "${DRY_RUN}" = "1" ] && log "DRY RUN — no files will be modified"

# -------------------------------------------------------------------
# Backup
# -------------------------------------------------------------------
BACKUP_DIR="${PROJECT_DIR}/.bootstrap-backup-$(date -u +%Y%m%dT%H%M%SZ)"
if [ "${DRY_RUN}" = "0" ]; then
  mkdir -p "${BACKUP_DIR}"
  cp "${MAIN_PY}"      "${BACKUP_DIR}/main.py.bak"
  cp "${INDEX_HTML}"   "${BACKUP_DIR}/index.html.bak"
  cp "${REQUIREMENTS}" "${BACKUP_DIR}/requirements.txt.bak"
  [ -f "${PRUNE_SH}" ] && cp "${PRUNE_SH}" "${BACKUP_DIR}/prune_db.sh.bak" || true
  log "Backups written to ${BACKUP_DIR}"
fi

run_py() {
  # Run a python3 -c snippet, or print it under --dry-run
  if [ "${DRY_RUN}" = "1" ]; then
    echo "----- would run -----"
    echo "$1"
    echo "---------------------"
  else
    python3 -c "$1"
  fi
}

# ===================================================================
# FIX 1a (backend) — sanitise_item_link()
# ===================================================================
log "FIX 1a: backend link sanitiser (sanitise_item_link)"

if grep -q "def sanitise_item_link" "${MAIN_PY}"; then
  log "  already present — skipping"
else
  run_py "
import re

path = '${MAIN_PY}'
src = open(path).read()

marker = '''
# --- FIX 1: sanitise_item_link -------------------------------------------
# Strips non-http/https schemes (e.g. javascript:, data:, vbscript:) from
# feed item links before they are stored in the database.  Defence-in-depth
# against stored XSS via malicious feed content.
def sanitise_item_link(link: str) -> str:
    \"\"\"Return link unchanged if http/https/relative, else empty string.\"\"\"
    if not link:
        return \"\"
    try:
        scheme = urlparse(link).scheme.lower()
        return link if scheme in (\"http\", \"https\", \"\") else \"\"
    except Exception:
        return \"\"
# -------------------------------------------------------------------------
'''

anchor = 'def validate_feed_url(url: str) -> str:'
idx = src.index(anchor)
# insert after the validate_feed_url function (find its closing 'return url')
end_idx = src.index('    return url', idx) + len('    return url')
src = src[:end_idx] + '\n' + marker + src[end_idx:]

# Now use it inside refresh_one_feed(): patch the link assignment line
old = '            link      = getattr(entry, \"link\", \"\") or feed[\"html_url\"] or \"\"'
new = '''            # --- FIX 1: sanitise link before storage -------------------------
            raw_link  = getattr(entry, \"link\", \"\") or feed[\"html_url\"] or \"\"
            link      = sanitise_item_link(raw_link) or feed[\"html_url\"] or \"\"
            # -------------------------------------------------------------------'''

if old not in src:
    raise SystemExit('FIX 1a: could not find link assignment line — main.py structure may differ from expected')

src = src.replace(old, new)
open(path, 'w').write(src)
print('  patched OK')
"
fi

# ===================================================================
# FIX 1b (frontend) — safeHref()
# ===================================================================
log "FIX 1b: frontend safeHref() guard"

if grep -q "function safeHref" "${INDEX_HTML}"; then
  log "  already present — skipping"
else
  run_py "
path = '${INDEX_HTML}'
src = open(path).read()

helper = '''
    // --- FIX 1 (frontend, defence-in-depth): safeHref -----------------------
    // Validates that a URL uses http or https before placing it in an anchor
    // href.  Prevents javascript: / data: / vbscript: XSS via feed item links
    // that slipped past backend sanitisation (e.g. items already in the DB).
    function safeHref(url) {
      if (!url) return \"#\";
      try {
        const u = new URL(url, location.href);
        return (u.protocol === \"http:\" || u.protocol === \"https:\") ? url : \"#\";
      } catch {
        return \"#\";
      }
    }
    // -------------------------------------------------------------------------
'''

anchor = 'function esc(v) {'
idx = src.index(anchor)
end_idx = src.index('}', idx) + 1
src = src[:end_idx] + '\n' + helper + src[end_idx:]

old = '<a href=\"\${esc(item.link)}\" target=\"_blank\" rel=\"noopener\">\${esc(item.title)}</a>'
new = '<a href=\"\${esc(safeHref(item.link))}\" target=\"_blank\" rel=\"noopener\">\${esc(item.title)}</a>'

if old not in src:
    raise SystemExit('FIX 1b: could not find item link anchor — index.html structure may differ from expected')

src = src.replace(old, new)
open(path, 'w').write(src)
print('  patched OK')
"
fi

# ===================================================================
# FIX 2 — global socket timeout for feedparser
# ===================================================================
log "FIX 2: feedparser global socket timeout"

if grep -q "socket.setdefaulttimeout" "${MAIN_PY}"; then
  log "  already present — skipping"
else
  run_py "
path = '${MAIN_PY}'
src = open(path).read()

old = '''async def lifespan(app: FastAPI):
    init_db()'''

new = '''async def lifespan(app: FastAPI):
    # --- FIX 2: global socket timeout ----------------------------------------
    # feedparser.parse() has no timeout parameter and relies on
    # socket.getdefaulttimeout().  Without this, a stalling feed server holds
    # a worker thread indefinitely and can exhaust the thread pool, causing
    # _refresh_lock to be held permanently with no visible error.
    import socket
    socket.setdefaulttimeout(30)
    # -------------------------------------------------------------------------
    init_db()'''

if old not in src:
    raise SystemExit('FIX 2: could not find lifespan() init_db() call — main.py structure may differ from expected')

src = src.replace(old, new)
open(path, 'w').write(src)
print('  patched OK')
"
fi

# ===================================================================
# FIX 3 — defusedxml + recursion cap on OPML parsing
# ===================================================================
log "FIX 3: defusedxml + recursion cap for OPML import/seed"

if grep -q "defusedxml" "${MAIN_PY}"; then
  log "  already present — skipping"
else
  run_py "
path = '${MAIN_PY}'
src = open(path).read()

# --- 3a: seed_default_profile() — ET.parse -> SafeET.parse ---
old_a = '''    try:
        tree = ET.parse(seed_file)
        root = tree.getroot()'''
new_a = '''    try:
        # --- FIX 3a: use SafeET for parsing untrusted/external XML files ---
        import defusedxml.ElementTree as SafeET
        tree = SafeET.parse(str(seed_file))
        # --------------------------------------------------------------------
        root = tree.getroot()'''

if old_a not in src:
    raise SystemExit('FIX 3a: could not find seed_default_profile ET.parse call')
src = src.replace(old_a, new_a)

# --- 3b: import_profile_opml() — ET.fromstring -> SafeET.fromstring ---
old_b = '''        root = ET.fromstring(content)
        body = root.find(\"body\")
        if body is None:
            raise HTTPException(status_code=400, detail=\"Invalid OPML: missing body.\")

        imported_feeds = []
        def walk_nodes(node, category=\"Uncategorised\"):
            # SEC-6: cap total feeds per import
            if len(imported_feeds) >= MAX_IMPORT_FEEDS:
                return
            for child in list(node):'''

new_b = '''        # --- FIX 3b: use defusedxml to parse uploaded OPML -------------------
        # Protects against Billion Laughs entity-expansion DoS.
        import defusedxml.ElementTree as SafeET
        root = SafeET.fromstring(content)
        # ---------------------------------------------------------------------
        body = root.find(\"body\")
        if body is None:
            raise HTTPException(status_code=400, detail=\"Invalid OPML: missing body.\")

        imported_feeds = []
        # --- FIX 3c: recursion depth cap -------------------------------------
        def walk_nodes(node, category=\"Uncategorised\", _depth=0):
            if len(imported_feeds) >= MAX_IMPORT_FEEDS or _depth > 20:
                return
            for child in list(node):'''

if old_b not in src:
    raise SystemExit('FIX 3b: could not find import_profile_opml ET.fromstring/walk_nodes block')
src = src.replace(old_b, new_b)

# --- 3c (cont.): pass _depth through the recursive call ---
old_c = '''                    next_cat = child.attrib.get(\"title\") or child.attrib.get(\"text\") or category
                    walk_nodes(child, next_cat)

        walk_nodes(body)'''
new_c = '''                    next_cat = child.attrib.get(\"title\") or child.attrib.get(\"text\") or category
                    walk_nodes(child, next_cat, _depth + 1)
        # ---------------------------------------------------------------------

        walk_nodes(body)'''

if old_c not in src:
    raise SystemExit('FIX 3c: could not find recursive walk_nodes() call in import_profile_opml')
src = src.replace(old_c, new_c)

open(path, 'w').write(src)
print('  patched OK')
"
fi

# ===================================================================
# requirements.txt — remove unused 'requests', bump feedparser, add defusedxml
# ===================================================================
log "requirements.txt: cleanup (remove requests, bump feedparser, add defusedxml)"

if grep -q "^defusedxml" "${REQUIREMENTS}"; then
  log "  already present — skipping"
else
  run_py "
path = '${REQUIREMENTS}'
lines = open(path).read().splitlines()

out = []
for line in lines:
    if line.startswith('requests=='):
        continue  # unused dependency
    if line.startswith('feedparser=='):
        out.append('feedparser==6.0.12')
        continue
    out.append(line)

if not any(l.startswith('defusedxml') for l in out):
    out.append('defusedxml==0.7.1')

open(path, 'w').write('\n'.join(out) + '\n')
print('  patched OK')
"
fi

# ===================================================================
# scripts/prune_db.sh — fix PROJECT_DIR resolution for standalone/cron use
# ===================================================================
log "scripts/prune_db.sh: fix standalone PROJECT_DIR resolution"

if [ ! -f "${PRUNE_SH}" ]; then
  log "  ${PRUNE_SH} not found — skipping (not generated by this setup?)"
elif grep -q 'SCRIPT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE\[0\]}")" && pwd)"' "${PRUNE_SH}"; then
  log "  already present — skipping"
else
  if [ "${DRY_RUN}" = "1" ]; then
    echo "----- would rewrite ${PRUNE_SH} -----"
    echo "  PROJECT_DIR derived from \${BASH_SOURCE[0]} instead of relying on"
    echo "  an inherited environment variable."
    echo "-------------------------------------"
  else
    cat > "${PRUNE_SH}" << 'PRUNEEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
DB="${PROJECT_DIR}/data/opml_reader.sqlite3"
DEFAULT_DAYS=90

# Per-feed max_age_days pruning (uses fetched_at, not published)
sqlite3 "${DB}" "
  DELETE FROM items
  WHERE is_read    = 1
    AND is_starred = 0
    AND feed_id IN (SELECT id FROM feeds WHERE max_age_days IS NOT NULL AND max_age_days > 0)
    AND fetched_at < datetime('now', '-' || (
          SELECT max_age_days FROM feeds WHERE id = items.feed_id
        ) || ' days');
"
# Global fallback for feeds with no max_age_days set
sqlite3 "${DB}" "
  DELETE FROM items
  WHERE is_read    = 1
    AND is_starred = 0
    AND fetched_at < datetime('now', '-${DEFAULT_DAYS} days')
    AND feed_id IN (SELECT id FROM feeds WHERE max_age_days IS NULL OR max_age_days = 0);
"
sqlite3 "${DB}" "VACUUM;"
echo "$(date -u +%FT%TZ) pruned items older than per-feed max_age_days (default ${DEFAULT_DAYS}d). DB: $(du -sh "${DB}" | cut -f1)"
PRUNEEOF
    chmod +x "${PRUNE_SH}"
    log "  patched OK"
  fi
fi

# ===================================================================
# Syntax check + rebuild prompt
# ===================================================================
if [ "${DRY_RUN}" = "0" ]; then
  log "Verifying main.py syntax..."
  python3 -m py_compile "${MAIN_PY}" && log "  OK"

  echo
  log "All patches applied. Backups in: ${BACKUP_DIR}"
  echo
  log "Next steps:"
  echo "    cd ${PROJECT_DIR}"
  echo "    docker compose build opml-reader"
  echo "    docker compose up -d"
  echo
  log "To roll back:"
  echo "    cp ${BACKUP_DIR}/main.py.bak       ${MAIN_PY}"
  echo "    cp ${BACKUP_DIR}/index.html.bak    ${INDEX_HTML}"
  echo "    cp ${BACKUP_DIR}/requirements.txt.bak ${REQUIREMENTS}"
  [ -f "${BACKUP_DIR}/prune_db.sh.bak" ] && echo "    cp ${BACKUP_DIR}/prune_db.sh.bak   ${PRUNE_SH}"
else
  echo
  log "Dry run complete. Re-run without --dry-run to apply."
fi
