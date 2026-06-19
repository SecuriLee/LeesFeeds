#!/usr/bin/env bash
set -euo pipefail

# ===================================================================
# bootstrap.sh — Lee's Feeds: install / update to known-good (v2)
#
# Idempotent "overwrite with known-good" deployer for Lee's Feeds.
#
#   - Fresh install (no ~/leesfeeds): generates the complete stack —
#     Dockerfile, docker-compose.yml, Caddyfile (with CSP), app code,
#     requirements, seed OPML, helper scripts.
#   - Existing install (any version, patched or not): overwrites all
#     generated code/config with the current known-good versions.
#     Re-running always converges to the same state — no anchor
#     matching, no "could not find expected block" failures.
#
# DATA SAFETY — the following are NEVER overwritten by this script:
#   - data/                  (SQLite DB; data/seed.opml only written
#                              if it doesn't already exist)
#   - caddy/certs/*.pem      (TLS cert/key; only fetched if missing)
#
# ENVIRONMENT-DERIVED files are always REGENERATED (cheap, deterministic
# from `tailscale` commands — safe to redo every run):
#   - .env
#   - caddy/Caddyfile        (hostname re-detected; CSP/security headers
#                              baked in)
#
# Security fixes baked into this version's app/main.py and
# app/static/index.html (see SECURITY.md-equivalent notes inline):
#   FIX 1 — sanitise_item_link() + safeHref(): blocks javascript:/data:
#           links in feed items (stored XSS)
#   FIX 2 — socket.setdefaulttimeout(30): prevents feedparser hangs from
#           exhausting the refresh thread pool
#   FIX 3 — defusedxml + recursion cap: blocks XML entity-expansion DoS
#           and unbounded OPML nesting on import
#   FIX 5 — Content-Security-Policy + Permissions-Policy headers (Caddy)
#   FIX NEW-2 — defusedxml exceptions return 400 not 500 on OPML import
#   FIX NEW-3 — seed_default_profile() logs via logger, not print()
#   + requirements.txt: removed unused 'requests', feedparser 6.0.12,
#     defusedxml==0.7.1
#   + scripts/prune_db.sh: self-resolving PROJECT_DIR (works under cron)
#
# STILL OPEN (not fixed by this script — tracked separately):
#   - Finding 1: SSRF — validate_feed_url() does not resolve hostnames,
#     so domains resolving to private/metadata IPs are not blocked.
#   - CSP uses 'unsafe-inline' for script-src/style-src (inline JS/CSS
#     in index.html not yet externalised).
#
# Usage:
#   ./bootstrap.sh                # install/update ~/leesfeeds
#   ./bootstrap.sh /path/to/proj  # install/update a specific path
#   ./bootstrap.sh --dry-run      # show what would be written, do nothing
# ===================================================================

DRY_RUN=0
VERBOSE=0
PROJECT_DIR="${HOME}/leesfeeds"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --verbose) VERBOSE=1 ;;
    *) PROJECT_DIR="$arg" ;;
  esac
done

log()  { echo "[bootstrap] $*"; }
vlog() { [ "${VERBOSE}" = "1" ] && echo "[bootstrap] $*" || true; }
fail() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

# write_file <path> <description> — reads heredoc content from stdin and
# writes it to <path>, unless --dry-run (in which case it just announces).
write_file() {
  local path="$1"
  local desc="$2"
  if [ "${DRY_RUN}" = "1" ]; then
    log "would write: ${path}  (${desc})"
    cat > /dev/null   # consume stdin
  else
    mkdir -p "$(dirname "${path}")"
    cat > "${path}"
    vlog "wrote: ${path}"
  fi
}

# write_file_exec — same as write_file but chmod +x afterwards
write_file_exec() {
  local path="$1"
  local desc="$2"
  if [ "${DRY_RUN}" = "1" ]; then
    log "would write (exec): ${path}  (${desc})"
    cat > /dev/null
  else
    mkdir -p "$(dirname "${path}")"
    cat > "${path}"
    chmod +x "${path}"
    vlog "wrote (exec): ${path}"
  fi
}

log "Target: ${PROJECT_DIR}"
[ "${DRY_RUN}" = "1" ] && log "DRY RUN — no files will be written"

if ! command -v docker >/dev/null 2>&1; then
  fail "docker is not installed or not in PATH."
fi
if ! docker compose version >/dev/null 2>&1; then
  fail "docker compose is not available."
fi
if ! command -v tailscale >/dev/null 2>&1; then
  fail "tailscale is not installed or not in PATH.
Install/configure Tailscale first, then rerun this script."
fi

if [ "${DRY_RUN}" = "0" ]; then
  mkdir -p "${PROJECT_DIR}"
fi
cd "${PROJECT_DIR}" 2>/dev/null || cd "${HOME}"

# -------------------------------------------------------------------
# Backup of files we're about to overwrite (only if they already exist)
# -------------------------------------------------------------------
BACKUP_DIR="${PROJECT_DIR}/.bootstrap-backup-$(date -u +%Y%m%dT%H%M%SZ)"
EXISTING_FILES_FOUND=0
for f in app/main.py app/static/index.html app/static/styles.css \
         requirements.txt Dockerfile docker-compose.yml \
         caddy/Caddyfile scripts/prune_db.sh scripts/renew_certs.sh; do
  [ -f "${PROJECT_DIR}/${f}" ] && EXISTING_FILES_FOUND=1
done

if [ "${EXISTING_FILES_FOUND}" = "1" ] && [ "${DRY_RUN}" = "0" ]; then
  mkdir -p "${BACKUP_DIR}"
  for f in app/main.py app/static/index.html app/static/styles.css \
           requirements.txt Dockerfile docker-compose.yml \
           caddy/Caddyfile scripts/prune_db.sh scripts/renew_certs.sh; do
    if [ -f "${PROJECT_DIR}/${f}" ]; then
      mkdir -p "${BACKUP_DIR}/$(dirname "${f}")"
      cp "${PROJECT_DIR}/${f}" "${BACKUP_DIR}/${f}"
    fi
  done
  log "Existing files detected — backed up to ${BACKUP_DIR}"
elif [ "${EXISTING_FILES_FOUND}" = "0" ]; then
  log "No existing managed files found — fresh install"
fi


# ===================================================================
# .env + Tailscale hostname detection (always regenerated)
# ===================================================================
TS_HOST_IP="$(tailscale ip -4 | head -n 1)"
if [ -z "${TS_HOST_IP}" ]; then
  fail "could not determine Tailscale IPv4 address. Check that Tailscale is running and authenticated."
fi

TS_HOSTNAME="$(tailscale status --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
self = d.get('Self', {})
dns = self.get('DNSName', '')
print(dns.rstrip('.'))
" 2>/dev/null || true)"

if [ -z "${TS_HOSTNAME}" ]; then
  log "WARNING: could not detect Tailscale hostname automatically."
  log "You will need to set TS_HOSTNAME manually in caddy/Caddyfile."
  TS_HOSTNAME="YOUR-MACHINE.YOUR-TAILNET.ts.net"
fi

log "Tailscale IP: ${TS_HOST_IP}"
log "Tailscale hostname: ${TS_HOSTNAME}"

write_file ".env" "Tailscale-derived environment" << EOF
TS_HOST_IP=${TS_HOST_IP}
TS_HOSTNAME=${TS_HOSTNAME}
EOF

# ===================================================================
# Caddyfile — with CSP + Permissions-Policy baked in (FIX 5)
# ===================================================================
write_file "caddy/Caddyfile" "reverse proxy + security headers (incl. CSP)" << CADDYEOF
${TS_HOSTNAME} {
  tls /etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem

  reverse_proxy opml-reader:8080

  encode gzip

  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    Referrer-Policy "strict-origin-when-cross-origin"
    Content-Security-Policy "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' https: http: data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
    Permissions-Policy "geolocation=(), microphone=(), camera=(), payment=()"
    -Server
  }

  log {
    output stdout
    format console
  }
}

http://${TS_HOSTNAME} {
  redir https://{host}{uri} permanent
}
CADDYEOF

# ===================================================================
# scripts/renew_certs.sh (static)
# ===================================================================
write_file_exec "scripts/renew_certs.sh" "Tailscale TLS cert renewal helper" << 'CERTEOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
CERT_DIR="${PROJECT_DIR}/caddy/certs"

TS_HOSTNAME="$(tailscale status --json 2>/dev/null |
python3 -c "
import sys, json
d = json.load(sys.stdin)
self = d.get('Self', {})
print(self.get('DNSName', '').rstrip('.'))
")"

if [ -z "${TS_HOSTNAME}" ]; then
  echo "ERROR: Could not determine Tailscale hostname."
  exit 1
fi

echo "Fetching cert for: ${TS_HOSTNAME}"
sudo tailscale cert \
  --cert-file "${CERT_DIR}/cert.pem" \
  --key-file  "${CERT_DIR}/key.pem" \
  "${TS_HOSTNAME}"

sudo chmod 644 "${CERT_DIR}/cert.pem"
sudo chmod 640 "${CERT_DIR}/key.pem"

cd "${PROJECT_DIR}"
docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile 2>/dev/null \
  || docker compose restart caddy

echo "Done. Cert renewed and Caddy reloaded."
CERTEOF

# ===================================================================
# Initial TLS cert — fetch ONLY if missing (data-safety: don't churn
# a working cert on every re-run)
# ===================================================================
[ "${DRY_RUN}" = "0" ] && mkdir -p "${PROJECT_DIR}/caddy/certs"
if [ -f "${PROJECT_DIR}/caddy/certs/cert.pem" ] && [ -f "${PROJECT_DIR}/caddy/certs/key.pem" ]; then
  vlog "TLS cert already present — skipping fetch"
elif [ "${DRY_RUN}" = "1" ]; then
  log "would fetch initial Tailscale TLS cert for ${TS_HOSTNAME}"
else
  log "Fetching initial Tailscale TLS cert for ${TS_HOSTNAME}…"
  if sudo tailscale cert \
       --cert-file "${PROJECT_DIR}/caddy/certs/cert.pem" \
       --key-file  "${PROJECT_DIR}/caddy/certs/key.pem" \
       "${TS_HOSTNAME}" 2>/dev/null; then
    sudo chmod 644 "${PROJECT_DIR}/caddy/certs/cert.pem"
    sudo chmod 640 "${PROJECT_DIR}/caddy/certs/key.pem"
    log "Cert fetched successfully."
  else
    log "WARNING: tailscale cert fetch failed."
    log "Run manually before starting the stack:"
    log "  sudo tailscale cert --cert-file ${PROJECT_DIR}/caddy/certs/cert.pem \\"
    log "                       --key-file  ${PROJECT_DIR}/caddy/certs/key.pem \\"
    log "                       ${TS_HOSTNAME}"
  fi
fi


# ===================================================================
# docker-compose.yml (static)
# ===================================================================
write_file "docker-compose.yml" "compose stack definition" << 'EOF'
services:
  opml-reader:
    build: .
    container_name: opml-reader
    restart: unless-stopped
    environment:
      APP_TITLE: "Lee's Feeds"
      DATABASE_PATH: "/data/opml_reader.sqlite3"
      SEED_OPML_PATH: "/data/seed.opml"
      FEED_REFRESH_MINUTES: "30"
      MAX_ITEMS_PER_FEED: "100"
    volumes:
      - ./data:/data
    networks:
      - internal
    security_opt:
      - no-new-privileges:true

  caddy:
    image: caddy:2-alpine
    container_name: opml-caddy
    restart: unless-stopped
    ports:
      - "${TS_HOST_IP}:443:443"
      - "${TS_HOST_IP}:80:80"
    volumes:
      - ./caddy/Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy/certs:/etc/caddy/certs:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - internal
    security_opt:
      - no-new-privileges:true
    depends_on:
      - opml-reader

networks:
  internal:
    driver: bridge

volumes:
  caddy_data:
  caddy_config:
EOF

# ===================================================================
# Dockerfile (static)
# ===================================================================
write_file "Dockerfile" "container image definition" << 'EOF'
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

WORKDIR /app

RUN useradd --create-home --shell /usr/sbin/nologin appuser

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
EOF

# ===================================================================
# requirements.txt — with FIX 3/NEW-2 deps, no unused 'requests'
# ===================================================================
write_file "requirements.txt" "Python dependencies" << 'EOF'
fastapi==0.115.6
uvicorn[standard]==0.34.0
feedparser==6.0.12
beautifulsoup4==4.12.3
pydantic==2.10.4
python-multipart==0.0.20
defusedxml==0.7.1
EOF

# ===================================================================
# scripts/write_clean_opml.py + data/seed.opml — only generate seed.opml
# if it doesn't already exist (data-safety)
# ===================================================================
write_file "scripts/write_clean_opml.py" "seed OPML generator" << 'EOF'
import html
import xml.etree.ElementTree as ET
from pathlib import Path

feeds = {
    "News": [
        ("BBC News",                "https://www.bbc.co.uk/news/",              "http://feeds.bbci.co.uk/news/rss.xml?edition=int"),
        ("The Guardian UK",         "https://www.theguardian.com/uk",           "https://www.theguardian.com/uk/rss"),
        ("Telegraph News",          "https://www.telegraph.co.uk/news/",        "https://www.telegraph.co.uk/news/rss.xml"),
        ("Telegraph Travel",        "https://www.telegraph.co.uk/travel/",      "https://www.telegraph.co.uk/travel/rss.xml"),
        ("The Oatmeal",             "https://theoatmeal.com/",                  "https://theoatmeal.com/feed/rss"),
        ("Daily Beast",             "https://www.thedailybeast.com/",           "http://feeds.feedburner.com/thedailybeast/articles"),
        ("Mirror - Home",           "https://www.mirror.co.uk",                 "https://www.mirror.co.uk/rss.xml"),
        ("The Independent - News",  "https://www.independent.co.uk/news",       "https://www.independent.co.uk/news/rss"),
    ],
    "Sport": [
        ("BBC Football",            "https://www.bbc.co.uk/sport/football",     "http://feeds.bbci.co.uk/sport/football/rss.xml"),
        ("Guardian Sport",          "https://www.theguardian.com/uk/sport",     "https://www.theguardian.com/uk/sport/rss"),
        ("Guardian Football",       "https://www.theguardian.com/football",     "https://www.theguardian.com/football/rss"),
    ],
    "Security": [
        ("Krebs on Security",       "https://krebsonsecurity.com",              "https://krebsonsecurity.com/feed/"),
        ("Schneier on Security",    "https://www.schneier.com/blog/",           "https://www.schneier.com/blog/atom.xml"),
        ("SANS ISC Full",           "https://isc.sans.edu",                     "https://isc.sans.edu/rssfeed_full.xml"),
        ("Security Affairs",        "https://securityaffairs.com",              "https://securityaffairs.com/feed"),
        ("Graham Cluley",           "https://www.grahamcluley.com",             "https://www.grahamcluley.com/feed/"),
        ("NCSC UK",                 "https://www.ncsc.gov.uk",                  "https://www.ncsc.gov.uk/api/1/services/v1/all-rss-feed.xml"),
        ("The Register Security",   "https://www.theregister.com/security/",    "https://www.theregister.com/security/headlines.atom"),
        ("Acunetix Blog",           "https://www.acunetix.com/blog/",           "https://www.acunetix.com/blog/feed/"),
    ],
    "Tech": [
        ("Ars Technica",            "https://arstechnica.com",                  "https://feeds.arstechnica.com/arstechnica/index"),
        ("The Register",            "https://www.theregister.com/",             "https://www.theregister.com/headlines.atom"),
        ("TechCrunch",              "https://techcrunch.com",                   "https://techcrunch.com/feed/"),
        ("Wired",                   "https://www.wired.com/latest",             "https://www.wired.com/feed/rss"),
        ("Guardian Technology",     "https://www.theguardian.com/technology",   "https://www.theguardian.com/technology/rss"),
        ("Hacker News Front Page",  "https://news.ycombinator.com",             "https://hnrss.org/frontpage"),
        ("Hackaday",                "https://hackaday.com",                     "https://hackaday.com/blog/feed/"),
        ("Thurrott",                "https://www.thurrott.com",                 "https://www.thurrott.com/feed"),
    ],
}

opml = ET.Element("opml", {"version": "1.1"})
head = ET.SubElement(opml, "head")
ET.SubElement(head, "title").text = "Lee's Feeds"
body = ET.SubElement(opml, "body")

for category, category_feeds in feeds.items():
    cat = ET.SubElement(body, "outline", {"text": category, "title": category})
    for title, html_url, xml_url in category_feeds:
        ET.SubElement(cat, "outline", {
            "text":    html.unescape(title),
            "title":   html.unescape(title),
            "type":    "rss",
            "version": "RSS",
            "htmlUrl": html_url,
            "xmlUrl":  xml_url,
        })

Path("data").mkdir(exist_ok=True)
tree = ET.ElementTree(opml)
ET.indent(tree, space="  ")
tree.write("data/seed.opml", encoding="utf-8", xml_declaration=True)
print("Wrote data/seed.opml")
EOF

[ "${DRY_RUN}" = "0" ] && mkdir -p "${PROJECT_DIR}/data"
if [ -f "${PROJECT_DIR}/data/seed.opml" ]; then
  vlog "data/seed.opml already exists — leaving as-is (data-safety)"
elif [ "${DRY_RUN}" = "1" ]; then
  log "would generate: data/seed.opml"
else
  (cd "${PROJECT_DIR}" && python3 scripts/write_clean_opml.py > /dev/null)
  vlog "generated: data/seed.opml"
fi

# ===================================================================
# scripts/prune_db.sh — with self-resolving PROJECT_DIR (Finding 7 fix)
# ===================================================================
write_file_exec "scripts/prune_db.sh" "DB pruning script (cron-safe path resolution)" << 'PRUNEEOF'
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


# ===================================================================
# app/main.py — FastAPI backend (FIX 1, 2, 3, NEW-2, NEW-3 baked in)
# ===================================================================
write_file "app/main.py" "FastAPI backend" << 'MAINPYEOF'
import html
import ipaddress
import logging
import os
import re
import sqlite3
import threading
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, List
from urllib.parse import urlparse

import feedparser
import defusedxml.common
from bs4 import BeautifulSoup
from fastapi import FastAPI, HTTPException, Query, UploadFile, File
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

logger = logging.getLogger("leesfeeds")

APP_TITLE            = os.getenv("APP_TITLE",            "Lee's Feeds")
DATABASE_PATH        = os.getenv("DATABASE_PATH",        "/data/opml_reader.sqlite3")
SEED_OPML_PATH       = os.getenv("SEED_OPML_PATH",       "/data/seed.opml")
FEED_REFRESH_MINUTES = int(os.getenv("FEED_REFRESH_MINUTES", "30"))
MAX_ITEMS_PER_FEED   = int(os.getenv("MAX_ITEMS_PER_FEED",   "100"))
REFRESH_WORKERS      = int(os.getenv("REFRESH_WORKERS",      "8"))
MAX_IMPORT_SIZE      = 5 * 1024 * 1024
MAX_IMPORT_FEEDS     = 500

BASE_DIR   = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

_refresh_lock = threading.Lock()

SECURITY_KEYWORDS = [
    "cve", "ransomware", "breach", "zero-day", "zeroday", "exploit",
    "malware", "phishing", "vulnerability", "patch", "advisory",
    "microsoft", "defender", "entra", "identity", "cloud", "attack",
    "threat", "incident", "backdoor", "botnet", "supply chain",
]

_PRIVATE_NETS = [
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("127.0.0.0/8"),
    ipaddress.ip_network("169.254.0.0/16"),
    ipaddress.ip_network("100.64.0.0/10"),
    ipaddress.ip_network("::1/128"),
    ipaddress.ip_network("fc00::/7"),
    ipaddress.ip_network("fe80::/10"),
]

def validate_feed_url(url: str) -> str:
    """Raise HTTPException if url is not a safe http/https URL."""
    if not url:
        raise HTTPException(400, "URL is required.")
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise HTTPException(400, f"URL scheme '{parsed.scheme}' is not allowed. Use http or https.")
    hostname = parsed.hostname or ""
    if not hostname:
        raise HTTPException(400, "URL has no hostname.")
    try:
        addr = ipaddress.ip_address(hostname)
        for net in _PRIVATE_NETS:
            if addr in net:
                raise HTTPException(400, "URL resolves to a private/reserved address.")
    except ValueError:
        pass
    return url

# --- FIX 1: sanitise_item_link -------------------------------------------
# Strips non-http/https schemes (e.g. javascript:, data:, vbscript:) from
# feed item links before they are stored in the database.  Defence-in-depth
# against stored XSS via malicious feed content.
def sanitise_item_link(link: str) -> str:
    """Return link unchanged if http/https/relative, else empty string."""
    if not link:
        return ""
    try:
        scheme = urlparse(link).scheme.lower()
        return link if scheme in ("http", "https", "") else ""
    except Exception:
        return ""
# -------------------------------------------------------------------------

_write_lock = threading.Lock()

from contextlib import contextmanager

@contextmanager
def write_db():
    """Acquire write lock, yield a DB connection, commit on exit."""
    with _write_lock:
        with db() as conn:
            yield conn

def db():
    conn = sqlite3.connect(DATABASE_PATH, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn

def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()

def clean_text(value: Optional[str], max_len: Optional[int] = None) -> str:
    if not value: return ""
    value = html.unescape(str(value))
    value = BeautifulSoup(value, "html.parser").get_text(" ", strip=True)
    value = " ".join(value.split())
    if max_len and len(value) > max_len:
        return value[: max_len - 1].rstrip() + "…"
    return value

def init_db():
    Path(DATABASE_PATH).parent.mkdir(parents=True, exist_ok=True)
    with write_db() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS profiles (
                id   INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS feeds (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                profile_id    INTEGER NOT NULL DEFAULT 1,
                title         TEXT NOT NULL,
                category      TEXT NOT NULL,
                xml_url       TEXT NOT NULL,
                html_url      TEXT,
                last_checked  TEXT,
                last_error    TEXT,
                etag          TEXT,
                last_modified TEXT,
                max_volume    INTEGER,
                max_age_days  INTEGER,
                FOREIGN KEY(profile_id) REFERENCES profiles(id) ON DELETE CASCADE,
                UNIQUE(profile_id, xml_url)
            );
            CREATE TABLE IF NOT EXISTS items (
                id         INTEGER PRIMARY KEY AUTOINCREMENT,
                feed_id    INTEGER NOT NULL,
                guid       TEXT    NOT NULL UNIQUE,
                title      TEXT    NOT NULL,
                link       TEXT,
                teaser     TEXT,
                author     TEXT,
                published  TEXT,
                fetched_at TEXT    NOT NULL,
                is_read    INTEGER NOT NULL DEFAULT 0,
                is_starred INTEGER NOT NULL DEFAULT 0,
                read_at    TEXT,
                starred_at TEXT,
                image_url  TEXT,
                FOREIGN KEY(feed_id) REFERENCES feeds(id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_items_published ON items(published);
            CREATE INDEX IF NOT EXISTS idx_items_feed      ON items(feed_id);
            CREATE INDEX IF NOT EXISTS idx_items_read      ON items(is_read);
            CREATE INDEX IF NOT EXISTS idx_items_starred   ON items(is_starred);
            CREATE INDEX IF NOT EXISTS idx_items_fetched   ON items(fetched_at);
            CREATE INDEX IF NOT EXISTS idx_feeds_category  ON feeds(category);
            CREATE INDEX IF NOT EXISTS idx_feeds_profile   ON feeds(profile_id);
        """)
        for col, defn in [
            ("etag",          "TEXT"),
            ("last_modified", "TEXT"),
            ("max_volume",    "INTEGER"),
            ("max_age_days",  "INTEGER"),
        ]:
            try:
                conn.execute(f"ALTER TABLE feeds ADD COLUMN {col} {defn}")
            except sqlite3.OperationalError:
                pass
        conn.execute("INSERT OR IGNORE INTO profiles (id, name) VALUES (1, 'Default')")

def seed_default_profile():
    with db() as conn:
        count = conn.execute("SELECT COUNT(*) as c FROM feeds WHERE profile_id = 1").fetchone()["c"]
        if count > 0: return

    seed_file = Path(SEED_OPML_PATH)
    if not seed_file.exists(): return

    try:
        # --- FIX 3a: use SafeET for parsing untrusted/external XML files ---
        import defusedxml.ElementTree as SafeET
        tree = SafeET.parse(str(seed_file))
        # --------------------------------------------------------------------
        root = tree.getroot()
        body = root.find("body")
        if body is None: return

        feeds = []
        def walk(node, category="Uncategorised"):
            for child in list(node):
                xml_url  = child.attrib.get("xmlUrl")
                title    = child.attrib.get("title") or child.attrib.get("text") or "Untitled"
                html_url = child.attrib.get("htmlUrl")
                if xml_url:
                    feeds.append({
                        "title": clean_text(title),
                        "category": clean_text(category) or "Uncategorised",
                        "xml_url": xml_url,
                        "html_url": html_url
                    })
                else:
                    next_cat = child.attrib.get("title") or child.attrib.get("text") or category
                    walk(child, next_cat)

        walk(body)
        with write_db() as conn:
            for f in feeds:
                conn.execute("""
                    INSERT OR IGNORE INTO feeds (profile_id, title, category, xml_url, html_url)
                    VALUES (1, ?, ?, ?, ?)
                """, (f["title"], f["category"], f["xml_url"], f["html_url"]))
    except Exception as e:
        # --- FIX NEW-3: use logger for consistency with the rest of the app
        # (was print(), which doesn't carry severity/context and is easy to
        # miss in container logs versus structured logger output).
        logger.error(f"Error seeding default profile: {e}")

def normalise_published(entry) -> str:
    parsed = getattr(entry, "published_parsed", None) or getattr(entry, "updated_parsed", None)
    if parsed:
        try:
            return datetime(*parsed[:6], tzinfo=timezone.utc).isoformat()
        except (ValueError, TypeError):
            pass
    return utc_now()

def entry_summary(entry) -> str:
    if getattr(entry, "summary", None): return entry.summary
    if getattr(entry, "description", None): return entry.description
    content = getattr(entry, "content", None)
    if content and isinstance(content, list) and content:
        return content[0].get("value", "")
    return ""

def extract_image(entry, link: str) -> Optional[str]:
    try:
        media = getattr(entry, "media_content", None)
        if media and isinstance(media, list):
            for m in media:
                url = m.get("url", "")
                if url and url.startswith("http") and m.get("medium", "") in ("image", ""):
                    return url
        for enc in getattr(entry, "enclosures", None) or []:
            url = enc.get("href", "") or enc.get("url", "")
            if url and enc.get("type", "").startswith("image/"):
                return url
        thumb = getattr(entry, "media_thumbnail", None)
        if thumb and isinstance(thumb, list) and thumb:
            url = thumb[0].get("url", "")
            if url and url.startswith("http"): return url
        summary = entry_summary(entry)
        if summary:
            soup = BeautifulSoup(summary, "html.parser")
            img  = soup.find("img")
            if img:
                src = img.get("src", "")
                if src and src.startswith("http"): return src
    except Exception:
        pass
    return None

def _normalise_link(link: str) -> str:
    """Strip query string and fragment for duplicate-URL detection only."""
    if not link:
        return ""
    try:
        p = urlparse(link)
        return p._replace(query="", fragment="").geturl().rstrip("/")
    except Exception:
        return link

def _dedup_feed(conn, feed_id: int) -> int:
    """Remove duplicate items within a feed that share the same normalised
    link (i.e. identical path, differing only in tracking query params).
    Keeps the best copy: starred > unread > most-recent published > lowest id.
    Starred items are never deleted even when duplicates exist.
    Returns the number of rows deleted."""
    items = conn.execute("""
        SELECT id, link, is_starred, is_read, published
        FROM items
        WHERE feed_id = ? AND link IS NOT NULL AND link != ''
    """, (feed_id,)).fetchall()

    groups: dict = {}
    for item in items:
        key = _normalise_link(item["link"])
        if key:
            groups.setdefault(key, []).append(item)

    removed = 0
    for group in groups.values():
        if len(group) < 2:
            continue
        group.sort(key=lambda i: (
            i["is_starred"],
            not i["is_read"],
            i["published"] or "",
            -i["id"],
        ), reverse=True)
        delete_ids = [i["id"] for i in group[1:] if not i["is_starred"]]
        if not delete_ids:
            continue
        conn.execute(
            f"DELETE FROM items WHERE id IN ({','.join('?'*len(delete_ids))})",
            delete_ids
        )
        removed += len(delete_ids)
    return removed

def refresh_one_feed(feed) -> int:
    kwargs = {}
    if feed["etag"]:          kwargs["etag"]     = feed["etag"]
    if feed["last_modified"]: kwargs["modified"]  = feed["last_modified"]

    parsed = feedparser.parse(feed["xml_url"], **kwargs)
    now    = utc_now()
    error  = None
    count  = 0

    if getattr(parsed, "status", None) == 304:
        with write_db() as conn:
            conn.execute("UPDATE feeds SET last_checked = ? WHERE id = ?", (now, feed["id"]))
        return 0

    if parsed.bozo and getattr(parsed, "bozo_exception", None):
        exc = parsed.bozo_exception
        exc_name = type(exc).__name__
        NON_FATAL = {
            "CharacterEncodingOverride",
            "CharacterEncodingUnknown",
            "NonXMLContentType",
            "UndeclaredNamespace",
            "ThingsNobodyCaresAbout",
        }
        if exc_name not in NON_FATAL:
            error = str(exc)[:500]

    new_etag          = getattr(parsed, "etag",     None) or feed["etag"]
    new_last_modified = getattr(parsed, "modified", None) or feed["last_modified"]

    volume = feed["max_volume"] or MAX_ITEMS_PER_FEED

    with write_db() as conn:
        for entry in parsed.entries[:volume]:
            title     = clean_text(getattr(entry, "title", "Untitled story"), 300)
            # --- FIX 1: sanitise link before storage -------------------------
            raw_link  = getattr(entry, "link", "") or feed["html_url"] or ""
            link      = sanitise_item_link(raw_link) or feed["html_url"] or ""
            # -----------------------------------------------------------------
            teaser    = clean_text(entry_summary(entry), 420)
            author    = clean_text(getattr(entry, "author", ""), 120)
            published = normalise_published(entry)
            image_url = extract_image(entry, link)

            guid = getattr(entry, "id", None) or getattr(entry, "guid", None) or link or f'{feed["xml_url"]}:{title}:{published}'
            guid = guid[:512]

            try:
                conn.execute("""
                    INSERT INTO items (feed_id, guid, title, link, teaser, author, published, fetched_at, image_url)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (feed["id"], guid, title, link, teaser, author, published, now, image_url))
                count += 1
            except sqlite3.IntegrityError:
                pass

        _dedup_feed(conn, feed["id"])
        conn.execute(
            "UPDATE feeds SET last_checked = ?, last_error = ?, etag = ?, last_modified = ? WHERE id = ?",
            (now, error, new_etag, new_last_modified, feed["id"])
        )
    return count

def refresh_all_feeds():
    if not _refresh_lock.acquire(blocking=False):
        logger.info("Refresh already in progress, skipping.")
        return
    try:
        with db() as conn:
            feeds = conn.execute("SELECT * FROM feeds ORDER BY category, title").fetchall()
        with ThreadPoolExecutor(max_workers=REFRESH_WORKERS) as executor:
            futures = {executor.submit(refresh_one_feed, feed): feed for feed in feeds}
            for future in as_completed(futures):
                feed = futures[future]
                try:
                    future.result()
                except Exception as exc:
                    with write_db() as conn:
                        conn.execute("UPDATE feeds SET last_checked = ?, last_error = ? WHERE id = ?",
                                     (utc_now(), str(exc)[:500], feed["id"]))
    finally:
        _refresh_lock.release()

def refresh_loop():
    while True:
        time.sleep(max(FEED_REFRESH_MINUTES, 5) * 60)
        refresh_all_feeds()

@asynccontextmanager
async def lifespan(app: FastAPI):
    # --- FIX 2: global socket timeout ----------------------------------------
    # feedparser.parse() has no timeout parameter and relies on
    # socket.getdefaulttimeout().  Without this, a stalling feed server holds
    # a worker thread indefinitely and can exhaust the thread pool, causing
    # _refresh_lock to be held permanently with no visible error.
    import socket
    socket.setdefaulttimeout(30)
    # -------------------------------------------------------------------------
    init_db()
    seed_default_profile()
    threading.Thread(target=refresh_all_feeds, daemon=True).start()
    threading.Thread(target=refresh_loop,      daemon=True).start()
    yield

app = FastAPI(title=APP_TITLE, lifespan=lifespan, docs_url=None, redoc_url=None)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

class ItemState(BaseModel):
    is_read:    Optional[bool] = None
    is_starred: Optional[bool] = None

class FeedEdit(BaseModel):
    title: str
    category: str
    xml_url: str
    html_url: Optional[str] = ""
    max_volume: Optional[int] = None
    max_age_days: Optional[int] = None

class EntryEdit(BaseModel):
    title: str
    teaser: Optional[str] = ""

class ProfileCreate(BaseModel):
    name: str

class FeedCreate(BaseModel):
    title: str
    category: str
    xml_url: str
    html_url: Optional[str] = ""
    max_volume: Optional[int] = None
    max_age_days: Optional[int] = None

@app.get("/")
def index():
    return FileResponse(STATIC_DIR / "index.html")

@app.get("/api/profiles")
def get_profiles():
    with db() as conn:
        rows = conn.execute("SELECT * FROM profiles ORDER BY id ASC").fetchall()
    return [dict(r) for r in rows]

@app.post("/api/profiles")
def create_profile(p: ProfileCreate):
    try:
        with write_db() as conn:
            cur = conn.execute("INSERT INTO profiles (name) VALUES (?)", (p.name,))
            return {"id": cur.lastrowid, "name": p.name}
    except sqlite3.IntegrityError:
        raise HTTPException(400, "Profile name already occupied.")

@app.get("/api/meta")
def meta(profile_id: int = 1):
    with db() as conn:
        feed_count    = conn.execute("SELECT COUNT(*) AS c FROM feeds WHERE profile_id = ?", (profile_id,)).fetchone()["c"]
        item_count    = conn.execute("SELECT COUNT(*) AS c FROM items i JOIN feeds f ON i.feed_id = f.id WHERE f.profile_id = ?", (profile_id,)).fetchone()["c"]
        unread_count  = conn.execute("SELECT COUNT(*) AS c FROM items i JOIN feeds f ON i.feed_id = f.id WHERE i.is_read = 0 AND f.profile_id = ?", (profile_id,)).fetchone()["c"]
        starred_count = conn.execute("SELECT COUNT(*) AS c FROM items i JOIN feeds f ON i.feed_id = f.id WHERE i.is_starred = 1 AND f.profile_id = ?", (profile_id,)).fetchone()["c"]
        error_count   = conn.execute("SELECT COUNT(*) AS c FROM feeds WHERE last_error IS NOT NULL AND last_error != '' AND profile_id = ?", (profile_id,)).fetchone()["c"]
        categories    = conn.execute("SELECT category, COUNT(*) AS feed_count FROM feeds WHERE profile_id = ? GROUP BY category ORDER BY category", (profile_id,)).fetchall()

    return {
        "title":         APP_TITLE,
        "feed_count":    feed_count,
        "item_count":    item_count,
        "unread_count":  unread_count,
        "starred_count": starred_count,
        "error_count":   error_count,
        "categories":    [dict(r) for r in categories],
    }

@app.get("/api/feeds")
def feeds(profile_id: int = 1):
    with db() as conn:
        rows = conn.execute("""
            SELECT f.*, COUNT(i.id) AS item_count, SUM(CASE WHEN i.is_read = 0 THEN 1 ELSE 0 END) AS unread_count
            FROM feeds f
            LEFT JOIN items i ON i.feed_id = f.id
            WHERE f.profile_id = ?
            GROUP BY f.id ORDER BY f.category, f.title
        """, (profile_id,)).fetchall()
    return [dict(r) for r in rows]

@app.post("/api/feeds")
def add_feed(f: FeedCreate, profile_id: int = 1):
    validate_feed_url(f.xml_url)
    if f.html_url: validate_feed_url(f.html_url)
    try:
        with write_db() as conn:
            cur = conn.execute("""
                INSERT INTO feeds (profile_id, title, category, xml_url, html_url, max_volume, max_age_days)
                VALUES (?, ?, ?, ?, ?, ?, ?)
            """, (profile_id, f.title, f.category, f.xml_url, f.html_url, f.max_volume, f.max_age_days))
            return {"id": cur.lastrowid}
    except sqlite3.IntegrityError:
        raise HTTPException(400, "Feed tracking conflict.")

@app.put("/api/feeds/{feed_id}")
def edit_feed(feed_id: int, f: FeedEdit):
    validate_feed_url(f.xml_url)
    if f.html_url: validate_feed_url(f.html_url)
    with write_db() as conn:
        cur = conn.execute("""
            UPDATE feeds SET title = ?, category = ?, xml_url = ?, html_url = ?,
                             max_volume = ?, max_age_days = ?
            WHERE id = ?
        """, (f.title, f.category, f.xml_url, f.html_url, f.max_volume, f.max_age_days, feed_id))
        if cur.rowcount == 0: raise HTTPException(404, "Feed stream not found.")
    return {"status": "updated"}

@app.delete("/api/feeds/{feed_id}")
def delete_feed(feed_id: int):
    with write_db() as conn:
        conn.execute("DELETE FROM feeds WHERE id = ?", (feed_id,))
    return {"status": "deleted"}

@app.get("/api/health")
def health(profile_id: int = 1):
    with db() as conn:
        rows = conn.execute("""
            SELECT f.id, f.title, f.category, f.xml_url, f.html_url, f.last_checked, f.last_error,
                   f.max_volume, f.max_age_days,
                   COUNT(i.id) AS item_count, SUM(CASE WHEN i.is_read = 0 THEN 1 ELSE 0 END) AS unread_count,
                   MAX(i.fetched_at) AS last_item_fetched_at
            FROM feeds f
            LEFT JOIN items i ON i.feed_id = f.id
            WHERE f.profile_id = ?
            GROUP BY f.id
            ORDER BY f.category, f.title
        """, (profile_id,)).fetchall()
    output = []
    for row in rows:
        d = dict(row)
        d["status"] = "error" if d["last_error"] else ("never_checked" if not d["last_checked"] else "healthy")
        output.append(d)
    return output

@app.post("/api/feeds/{feed_id}/refresh")
def refresh_feed(feed_id: int):
    with db() as conn:
        row = conn.execute("SELECT * FROM feeds WHERE id = ?", (feed_id,)).fetchone()
    if not row:
        raise HTTPException(404, "Feed not found.")
    threading.Thread(target=refresh_one_feed, args=(dict(row),), daemon=True).start()
    return {"status": "started", "feed_id": feed_id, "refreshed_at": utc_now()}

def _normalise_link(link: str) -> str:
    """Strip query string and fragment for duplicate-detection only."""
    if not link:
        return ""
    try:
        p = urlparse(link)
        return p._replace(query="", fragment="").geturl().rstrip("/")
    except Exception:
        return link

@app.post("/api/prune")
def prune(profile_id: int = 1):
    now = utc_now()
    deleted = 0
    dupes = 0
    with write_db() as conn:
        # Age-based pruning
        feeds_with_age = conn.execute("""
            SELECT id, max_age_days FROM feeds
            WHERE profile_id = ? AND max_age_days IS NOT NULL AND max_age_days > 0
        """, (profile_id,)).fetchall()
        for f in feeds_with_age:
            cur = conn.execute("""
                DELETE FROM items
                WHERE feed_id = ? AND is_read = 1 AND is_starred = 0
                  AND fetched_at < datetime('now', ? || ' days')
            """, (f["id"], f"-{f['max_age_days']}"))
            deleted += cur.rowcount
        cur = conn.execute("""
            DELETE FROM items
            WHERE is_read = 1 AND is_starred = 0
              AND fetched_at < datetime('now', '-90 days')
              AND feed_id IN (
                SELECT id FROM feeds
                WHERE profile_id = ? AND (max_age_days IS NULL OR max_age_days = 0)
              )
        """, (profile_id,))
        deleted += cur.rowcount

        # URL deduplication — same logic as _dedup_feed() run on each refresh,
        # but run here across all feeds to catch duplicates that pre-date the fix.
        all_feeds = conn.execute(
            "SELECT id FROM feeds WHERE profile_id = ?", (profile_id,)
        ).fetchall()
        for feed in all_feeds:
            dupes += _dedup_feed(conn, feed["id"])

        conn.execute("VACUUM")
    return {"status": "ok", "deleted": deleted, "dupes_removed": dupes, "pruned_at": now}

@app.get("/api/items")
def items(
    profile_id:      int = 1,
    category:        Optional[str]  = None,
    feed_id:         Optional[int]  = None,
    q:               Optional[str]  = None,
    unread:          Optional[bool] = None,
    starred:         Optional[bool] = None,
    security_digest: Optional[bool] = None,
    limit:           int = Query(30, ge=1, le=500),
    offset:          int = Query(0, ge=0),
):
    where  = ["f.profile_id = ?"]
    params = [profile_id]

    if category:        where.append("f.category = ?");            params.append(category)
    if feed_id:         where.append("f.id = ?");                  params.append(feed_id)
    if q:
        where.append("(i.title LIKE ? OR i.teaser LIKE ? OR f.title LIKE ?)")
        like = f"%{q}%"
        params.extend([like, like, like])
    if unread  is True: where.append("i.is_read = 0")
    if starred is True: where.append("i.is_starred = 1")

    if security_digest is True:
        kw_parts = []
        for kw in SECURITY_KEYWORDS:
            kw_parts.append("LOWER(i.title || ' ' || COALESCE(i.teaser,'') || ' ' || f.title) LIKE ?")
            params.append(f"%{kw}%")
        where.append("(f.category = 'Security' OR " + " OR ".join(kw_parts) + ")")

    sql_where = "WHERE " + " AND ".join(where)

    with db() as conn:
        rows = conn.execute(f"""
            SELECT i.id, i.title, i.link, i.teaser, i.author, i.published, i.fetched_at,
                   i.is_read, i.is_starred, i.read_at, i.starred_at, i.image_url,
                   f.title AS feed_title, f.category, f.html_url AS feed_homepage
            FROM items i
            JOIN feeds f ON f.id = i.feed_id
            {sql_where}
            ORDER BY datetime(i.published) DESC, i.id DESC LIMIT ? OFFSET ?
        """, (*params, limit, offset)).fetchall()
    return [dict(r) for r in rows]

@app.patch("/api/items/{item_id}")
def update_item(item_id: int, state: ItemState):
    updates = []
    params  = []
    now     = utc_now()
    if state.is_read is not None:
        updates += ["is_read = ?", "read_at = ?"]
        params  += [1 if state.is_read else 0, now if state.is_read else None]
    if state.is_starred is not None:
        updates += ["is_starred = ?", "starred_at = ?"]
        params  += [1 if state.is_starred else 0, now if state.is_starred else None]
    if not updates: raise HTTPException(400, "No data provided.")
    params.append(item_id)
    with write_db() as conn:
        cur = conn.execute(f"UPDATE items SET {', '.join(updates)} WHERE id = ?", params)
        if cur.rowcount == 0: raise HTTPException(404, "Item not found.")
        row = conn.execute("SELECT * FROM items WHERE id = ?", (item_id,)).fetchone()
        return dict(row)

@app.post("/api/items/mark-all-read")
def mark_all_read(profile_id: int = 1, category: Optional[str] = None, feed_id: Optional[int] = None):
    now = utc_now()
    where = ["is_read = 0", "feed_id IN (SELECT id FROM feeds WHERE profile_id = ?)"]
    params = [now, profile_id]
    if category:
        where.append("feed_id IN (SELECT id FROM feeds WHERE category = ?)")
        params.append(category)
    if feed_id:
        where.append("feed_id = ?")
        params.append(feed_id)
    sql = "UPDATE items SET is_read = 1, read_at = ? WHERE " + " AND ".join(where)
    with write_db() as conn:
        cur = conn.execute(sql, params)
        return {"updated": cur.rowcount, "read_at": now}

@app.post("/api/refresh")
def refresh():
    if _refresh_lock.locked():
        raise HTTPException(429, "Refresh already in progress.")
    threading.Thread(target=refresh_all_feeds, daemon=True).start()
    return {"status": "started", "refreshed_at": utc_now()}

@app.get("/api/refresh/status")
def refresh_status():
    return {"status": "running" if _refresh_lock.locked() else "idle"}

@app.get("/api/profiles/{profile_id}/export", response_class=Response)
def export_profile_opml(profile_id: int):
    with db() as conn:
        profile = conn.execute("SELECT name FROM profiles WHERE id = ?", (profile_id,)).fetchone()
        if not profile:
            raise HTTPException(status_code=404, detail="Profile not found.")
        feeds_list = conn.execute(
            "SELECT title, category, xml_url, html_url FROM feeds WHERE profile_id = ? ORDER BY category, title",
            (profile_id,)
        ).fetchall()

    opml = ET.Element("opml", {"version": "1.1"})
    head = ET.SubElement(opml, "head")
    ET.SubElement(head, "title").text = f"Exported Feeds - {profile['name']}"
    body = ET.SubElement(opml, "body")

    categories = {}
    for f in feeds_list:
        cat_name = f["category"] or "Uncategorised"
        if cat_name not in categories:
            categories[cat_name] = ET.SubElement(body, "outline", {"text": cat_name, "title": cat_name})
        ET.SubElement(categories[cat_name], "outline", {
            "text": f["title"], "title": f["title"],
            "type": "rss", "version": "RSS",
            "htmlUrl": f["html_url"] or "", "xmlUrl": f["xml_url"]
        })

    tree = ET.ElementTree(opml)
    ET.indent(tree, space="  ")
    xml_data = ET.tostring(opml, encoding="utf-8", xml_declaration=True)
    safe_name = re.sub(r"[^\w\-]", "_", profile["name"].lower())
    filename = f"feeds_{safe_name}.opml"
    return Response(content=xml_data, media_type="application/xml",
                    headers={"Content-Disposition": f'attachment; filename="{filename}"'})

@app.post("/api/profiles/{profile_id}/import")
async def import_profile_opml(profile_id: int, file: UploadFile = File(...)):
    with db() as conn:
        profile = conn.execute("SELECT id FROM profiles WHERE id = ?", (profile_id,)).fetchone()
        if not profile:
            raise HTTPException(status_code=404, detail="Target profile does not exist.")
    try:
        content = await file.read(MAX_IMPORT_SIZE + 1)
        if len(content) > MAX_IMPORT_SIZE:
            raise HTTPException(status_code=413, detail=f"OPML file exceeds {MAX_IMPORT_SIZE // 1024 // 1024}MB limit.")

        # --- FIX 3b: use defusedxml to parse uploaded OPML -------------------
        # Protects against Billion Laughs entity-expansion DoS.
        import defusedxml.ElementTree as SafeET
        root = SafeET.fromstring(content)
        # ---------------------------------------------------------------------
        body = root.find("body")
        if body is None:
            raise HTTPException(status_code=400, detail="Invalid OPML: missing body.")

        imported_feeds = []
        # --- FIX 3c: recursion depth cap -------------------------------------
        def walk_nodes(node, category="Uncategorised", _depth=0):
            if len(imported_feeds) >= MAX_IMPORT_FEEDS or _depth > 20:
                return
            for child in list(node):
                if len(imported_feeds) >= MAX_IMPORT_FEEDS:
                    break
                xml_url  = child.attrib.get("xmlUrl")
                title    = child.attrib.get("title") or child.attrib.get("text") or "Untitled"
                html_url = child.attrib.get("htmlUrl") or ""
                if xml_url:
                    try:
                        validate_feed_url(xml_url)
                    except HTTPException:
                        continue
                    imported_feeds.append({
                        "title":    clean_text(title),
                        "category": clean_text(category) or "Uncategorised",
                        "xml_url":  xml_url,
                        "html_url": html_url,
                    })
                else:
                    next_cat = child.attrib.get("title") or child.attrib.get("text") or category
                    walk_nodes(child, next_cat, _depth + 1)
        # ---------------------------------------------------------------------

        walk_nodes(body)
        inserted_count = 0
        new_feed_ids = []
        with write_db() as conn:
            for f in imported_feeds:
                cur = conn.execute("""
                    INSERT OR IGNORE INTO feeds (profile_id, title, category, xml_url, html_url)
                    VALUES (?, ?, ?, ?, ?)
                """, (profile_id, f["title"], f["category"], f["xml_url"], f["html_url"]))
                if cur.rowcount > 0:
                    new_feed_ids.append(cur.lastrowid)
                    inserted_count += 1

        if new_feed_ids:
            with db() as conn:
                new_feeds = conn.execute(
                    f"SELECT * FROM feeds WHERE id IN ({','.join('?'*len(new_feed_ids))})",
                    new_feed_ids
                ).fetchall()
            def refresh_new():
                for feed in new_feeds:
                    try:
                        refresh_one_feed(dict(feed))
                    except Exception as exc:
                        with write_db() as conn:
                            conn.execute("UPDATE feeds SET last_error = ? WHERE id = ?",
                                         (str(exc)[:500], feed["id"]))
            threading.Thread(target=refresh_new, daemon=True).start()

        return {"status": "success", "total_found": len(imported_feeds), "newly_added": inserted_count}
    except ET.ParseError:
        raise HTTPException(status_code=400, detail="Failed to parse OPML XML.")
    # --- FIX NEW-2: defusedxml raises its own exception types (DTDForbidden,
    # EntitiesForbidden, ExternalReferenceForbidden — all subclasses of
    # DefusedXmlException) for OPML files containing DOCTYPE/entity/external
    # reference declarations. Some legitimate feed-reader exports include a
    # DOCTYPE even without malicious intent. Without this handler these fell
    # through to the generic 500 below, giving the user an opaque error for
    # a file we can name a specific, actionable reason for rejecting.
    except defusedxml.common.DefusedXmlException:
        raise HTTPException(
            status_code=400,
            detail="OPML file uses a DOCTYPE/entity declaration, which is blocked for security. "
                   "Please remove the DOCTYPE and re-export, or contact the feed reader's vendor."
        )
    # -------------------------------------------------------------------------
    except HTTPException:
        raise
    except Exception as e:
        # SEC-11: log internally, return generic message
        logger.error(f"OPML import error: {e}")
        raise HTTPException(status_code=500, detail="Import failed due to an internal error.")
MAINPYEOF

# ===================================================================
# app/static/index.html — frontend (FIX 1 safeHref baked in)
# ===================================================================
write_file "app/static/index.html" "frontend UI" << 'FRONTENDHTML'
<!doctype html>
<html lang="en-GB">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1" />
  <title>Lee's Feeds</title>
  <link rel="icon" type="image/svg+xml" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 64 64'%3E%3Crect width='64' height='64' rx='6' fill='%230f172a'/%3E%3Crect x='10' y='8' width='44' height='48' rx='3' fill='none' stroke='%23fbbf24' stroke-width='3'/%3E%3Cpolyline points='42,8 54,8 54,20 42,20 42,8' fill='%230f172a' stroke='%23fbbf24' stroke-width='2.5' stroke-linejoin='round'/%3E%3Crect x='16' y='24' width='28' height='4' rx='1.5' fill='%23fbbf24'/%3E%3Crect x='16' y='32' width='22' height='2.5' rx='1' fill='%23fbbf24' opacity='.6'/%3E%3Crect x='16' y='37' width='26' height='2.5' rx='1' fill='%23fbbf24' opacity='.6'/%3E%3Crect x='16' y='42' width='18' height='2.5' rx='1' fill='%23fbbf24' opacity='.6'/%3E%3C/svg%3E" />
  <link rel="stylesheet" href="/static/styles.css" />
  <script>
    (function(){
      const t = localStorage.getItem("lf-theme");
      if (t === "light") document.documentElement.setAttribute("data-theme", "light");
    })();
  </script>
</head>
<body>
  <header class="hero">
    <div class="heroTitle">
      <h1 id="homeBtn" role="button" tabindex="0">Lee's Feeds</h1>
      <p id="stats" class="muted" style="cursor:pointer; display:flex; gap:14px; align-items:center;" title="Click to view feed errors"></p>
    </div>
    <div class="heroActions">
      <button id="themeToggleBtn" class="heroIconBtn secondary themeToggleBtn" aria-label="Toggle light/dark mode" title="Toggle theme">
        <svg class="iconSun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="5"/>
          <line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/>
          <line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/>
          <line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/>
          <line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>
        </svg>
        <svg class="iconMoon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>
        </svg>
      </button>
      <button id="healthBtn" class="heroIconBtn secondary" aria-label="Feed health" title="Feed health">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>
        </svg>
      </button>
      <button id="manageFeedsBtn" class="heroIconBtn secondary" aria-label="Manage feeds" title="Manage feeds">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <line x1="4" y1="21" x2="4" y2="14"/><line x1="4" y1="10" x2="4" y2="3"/>
          <line x1="12" y1="21" x2="12" y2="12"/><line x1="12" y1="8" x2="12" y2="3"/>
          <line x1="20" y1="21" x2="20" y2="16"/><line x1="20" y1="12" x2="20" y2="3"/>
          <line x1="1" y1="14" x2="7" y2="14"/>
          <line x1="9" y1="8" x2="15" y2="8"/>
          <line x1="17" y1="16" x2="23" y2="16"/>
        </svg>
      </button>
      <button id="markReadBtn" class="heroIconBtn secondary" aria-label="Mark shown read" title="Mark shown read">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="20 6 9 17 4 12"/>
        </svg>
      </button>
      <button id="refreshBtn" class="heroIconBtn" aria-label="Refresh feeds" title="Refresh feeds">
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <polyline points="23 4 23 10 17 10"/>
          <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/>
        </svg>
      </button>
    </div>
  </header>

  <nav class="mobileBar" aria-label="Mobile actions">
    <button class="mobileBarBrand mobileBarTitle" id="homeBtnMobile" aria-label="Home">Lee's Feeds</button>
    <button id="statsMobile" class="mobileBarStats" aria-label="Feed stats"></button>
    <span class="mobileBarSpacer"></span>
    <button id="themeToggleBtnMobile" class="mobileBarBtn" aria-label="Toggle theme">
      <svg class="iconSun" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <circle cx="12" cy="12" r="5"/>
        <line x1="12" y1="1" x2="12" y2="3"/><line x1="12" y1="21" x2="12" y2="23"/>
        <line x1="4.22" y1="4.22" x2="5.64" y2="5.64"/><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"/>
        <line x1="1" y1="12" x2="3" y2="12"/><line x1="21" y1="12" x2="23" y2="12"/>
        <line x1="4.22" y1="19.78" x2="5.64" y2="18.36"/><line x1="18.36" y1="5.64" x2="19.78" y2="4.22"/>
      </svg>
      <svg class="iconMoon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"/>
      </svg>
    </button>
    <button id="densityToggleBtnMobile" class="mobileBarBtn" aria-label="Toggle compact view">
      <svg class="iconComfortable" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <rect x="3" y="4" width="18" height="16" rx="2"/>
        <line x1="3" y1="11" x2="21" y2="11"/>
      </svg>
      <svg class="iconCompact" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <rect x="3" y="4" width="5" height="5" rx="1"/>
        <line x1="10" y1="6.5" x2="21" y2="6.5"/>
        <rect x="3" y="14" width="5" height="5" rx="1"/>
        <line x1="10" y1="16.5" x2="21" y2="16.5"/>
      </svg>
    </button>
    <button id="markReadBtnMobile" class="mobileBarBtn" aria-label="Mark shown read">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
        <polyline points="20 6 9 17 4 12"/>
      </svg>
    </button>
    <button id="refreshBtnMobile" class="mobileBarBtn" aria-label="Refresh feeds">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
        <polyline points="23 4 23 10 17 10"/>
        <path d="M20.49 15a9 9 0 1 1-2.12-9.36L23 10"/>
      </svg>
    </button>
    <button id="filterToggleBtnMobile" class="mobileBarBtn" aria-label="Filters" aria-expanded="false">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
        <line x1="3" y1="7" x2="21" y2="7"/>
        <line x1="3" y1="12" x2="21" y2="12"/>
        <line x1="3" y1="17" x2="21" y2="17"/>
      </svg>
    </button>
  </nav>

  <main>
    <section class="controls">
      <div class="profile-select-wrapper">
        <select id="profileSelect"></select>
      </div>
      <input id="search" type="search" placeholder="Search…" autocomplete="off" />
      <select id="category"><option value="">All categories</option></select>
      <select id="feed"><option value="">All feeds</option></select>
      
      <label class="toggle" id="unreadToggle">
        <input id="unreadOnly" type="checkbox" checked />
        <span>Unread only</span>
      </label>
      <label class="toggle" id="starredToggle">
        <input id="starredOnly" type="checkbox" />
        <span>Starred only</span>
      </label>
      <button id="filterToggleBtn" class="filterToggleBtn secondary" aria-expanded="false" aria-label="Filters">Filters</button>
    </section>

    <div id="filterDrawer" class="filterDrawer" hidden>
      <div class="filterDrawerInner">
        <div class="filterDrawerHandle"></div>
        <div class="filterDrawerRow">
          <select id="profileSelectDrawer"></select>
          <select id="categoryDrawer"><option value="">All categories</option></select>
        </div>
        <div class="filterDrawerRow">
          <select id="feedDrawer"><option value="">All feeds</option></select>
        </div>
        <input id="searchDrawer" type="search" placeholder="Search…" autocomplete="off" style="width:100%; box-sizing:border-box; min-height:44px; padding:10px 12px; border-radius:var(--radius); border:1px solid var(--border-color); background:var(--bg-app); font-size:16px; color:var(--text-main);" />
        <div class="filterDrawerChecks">
          <label class="toggle"><input id="unreadOnlyDrawer" type="checkbox" checked /><span>Unread only</span></label>
          <label class="toggle"><input id="starredOnlyDrawer" type="checkbox" /><span>Starred only</span></label>
        </div>
      </div>
    </div>
    
    <p id="status" class="status"></p>
    <section id="grid" class="grid"></section>
    <div id="filterDrawerOverlay"></div>
    <div id="toast" class="toast hidden">
      <span id="toastMsg"></span>
      <div id="toastActions" class="toastActions hidden">
        <button id="toastReloadBtn" class="toastBtn toastBtnPrimary">Reload articles</button>
        <button id="toastDismissBtn" class="toastBtn">Dismiss</button>
      </div>
    </div>
    <section id="healthPanel" class="healthPanel hidden"></section>

    <div id="editModal" class="modal hidden">
      <div class="modal-content">
        <h3 id="modalTitle" style="margin-bottom: 15px; font-weight: 800;">Edit Properties</h3>
        <div id="modalBody"></div>
        <div class="modal-actions">
          <button id="modalCancelBtn" class="secondary">Cancel</button>
          <button id="modalSaveBtn">Save Changes</button>
        </div>
      </div>
    </div>
  </main>

  <script>
    const state = {
      currentProfileId: 1,
      profiles: [],
      meta: null,
      feeds: [],
      items: [],
      health: [],
      mode: "stories",
      category: "",
      feedId: "",
      q: "",
      unreadOnly: true,
      starredOnly: false,
      offset: 0,
      limit: 30,
      hasMore: true,
      loadingMore: false,
      // Dedup tracking (FEATURE 2): maps article 'link' -> primary item
      // object currently rendered, when dedup is active (All Feeds view,
      // no category/feed filter). Reset in loadItems(), grown across
      // loadMoreItems() pages so duplicates arriving on later pages fold
      // into the already-rendered card instead of appearing separately.
      linkIndex: new Map()
    };

    const el = id => document.getElementById(id);

    function fmtDate(v) {
      if (!v) return "";
      const d = new Date(v);
      return isNaN(d) ? "" : new Intl.DateTimeFormat("en-GB", { dateStyle: "medium", timeStyle: "short" }).format(d);
    }

    function esc(v) {
      return String(v ?? "").replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"','&quot;');
    }

    // --- FIX 1 (frontend, defence-in-depth): safeHref -----------------------
    // Validates that a URL uses http or https before placing it in an anchor
    // href.  Prevents javascript: / data: / vbscript: XSS via feed item links
    // that slipped past backend sanitisation (e.g. items already in the DB).
    function safeHref(url) {
      if (!url) return "#";
      try {
        const u = new URL(url, location.href);
        return (u.protocol === "http:" || u.protocol === "https:") ? url : "#";
      } catch {
        return "#";
      }
    }
    // -------------------------------------------------------------------------

    // --- FEATURE 2: cross-feed duplicate article merging ---------------------
    // Dedup applies only in strict "All Feeds" view (no category or feed
    // filter active) — per spec, category-filtered views (e.g. "Sport") show
    // each feed's copy separately.
    function dedupActive() {
      return !state.category && !state.feedId;
    }

    // Normalise a link for dedup-key comparison only (the original link is
    // still used for the rendered href). Strips query string and fragment,
    // since the same article syndicated into multiple feeds often carries
    // different tracking parameters per-feed
    // (e.g. ?at_medium=RSS&at_campaign=rss_sport vs ...=rss_news) while the
    // underlying article path is identical. Article URLs use unique path
    // segments (slugs/ids), so collapsing the query string carries
    // negligible risk of merging genuinely different articles.
    function normaliseLink(link) {
      if (!link) return "";
      try {
        const u = new URL(link, location.href);
        u.search = "";
        u.hash = "";
        return u.toString();
      } catch {
        return link;
      }
    }

    // Merge a freshly-fetched chunk of items against state.linkIndex.
    // Returns { toRender, toUpdate } where:
    //   toRender  - new primary items that need a new card appended
    //   toUpdate  - existing primary items whose merged state changed and
    //               whose existing card needs to be refreshed in place
    // Items whose link matches an existing primary are folded into that
    // primary's _dupes array (mutates the existing primary object).
    function mergeChunkForDedup(chunk) {
      if (!dedupActive()) {
        return { toRender: chunk, toUpdate: [] };
      }
      const toRender = [];
      const toUpdate = [];
      for (const item of chunk) {
        const key = normaliseLink(item.link) || `__nolink_${item.id}`;
        const existing = state.linkIndex.get(key);
        if (!existing) {
          item._dupes = [];
          state.linkIndex.set(key, item);
          toRender.push(item);
        } else {
          existing._dupes = existing._dupes || [];
          existing._dupes.push(item);
          // Merged is_read: unread until ALL copies are read.
          const wasRead = existing.is_read;
          existing.is_read = existing.is_read && item.is_read;
          // Merged is_starred: starred if ANY copy is starred.
          const wasStarred = existing.is_starred;
          existing.is_starred = existing.is_starred || item.is_starred;
          if (existing.is_read !== wasRead || existing.is_starred !== wasStarred) {
            toUpdate.push(existing);
          }
        }
      }
      return { toRender, toUpdate };
    }

    // All item ids represented by a (possibly merged) card's item object.
    function allIdsFor(item) {
      const ids = [item.id];
      if (item._dupes) ids.push(...item._dupes.map(d => d.id));
      return ids;
    }
    // ---------------------------------------------------------------------

    async function api(url, opts = {}) {
      const r = await fetch(url, { headers: { "Content-Type": "application/json" }, ...opts });
      if (!r.ok) throw new Error(await r.text());
      return r.json();
    }

    async function loadProfiles() {
      state.profiles = await api("/api/profiles");
      const sel = el("profileSelect");
      sel.innerHTML = "";
      state.profiles.forEach(p => {
        const o = document.createElement("option");
        o.value = p.id;
        o.textContent = p.name;
        sel.appendChild(o);
      });
      sel.value = state.currentProfileId;
    }

    async function loadMeta() {
      state.meta = await api(`/api/meta?profile_id=${state.currentProfileId}`);
      updateStats();
      const sel = el("category");
      const cur = sel.value;
      sel.innerHTML = `<option value="">All categories</option>`;
      state.meta.categories.forEach(c => {
        const o = document.createElement("option");
        o.value = c.category;
        o.textContent = `${c.category} (${c.feed_count})`;
        sel.appendChild(o);
      });
      sel.value = cur || state.category;
    }

    function updateStats() {
      if (!state.meta) return;
      const m = state.meta;
      const filterLabel = state.category ? ` · ${state.category}` : "";
      el("stats").innerHTML = `
        <span title="${m.feed_count} feeds">📡 ${m.feed_count}</span>
        <span title="${m.item_count} stories">📖 ${m.item_count}</span>
        <span title="${m.unread_count} unread">✉️ ${m.unread_count}</span>
        <span title="${m.starred_count} starred">⭐ ${m.starred_count}</span>
        ${m.error_count ? `<span title="${m.error_count} errors" style="color:var(--text-main); font-weight:bold;">⚠️ ${m.error_count}</span>` : ""}
        <span style="font-style:italic; color:var(--text-muted);">${filterLabel}</span>
      `;
      const mob = el("statsMobile");
      if (mob) mob.textContent = m.error_count ? `⚠️ ${m.error_count}` : "";
    }

    function updateStatusLabel() {
      const statusEl = el("status");
      if (!statusEl) return;
      // Use rendered card count rather than state.items.length: with dedup
      // active, state.items (raw, pre-merge) can be non-empty while no
      // primary cards are rendered (all loaded items were duplicates of
      // already-shown articles).
      if (el("grid").children.length === 0) {
        statusEl.textContent = state.unreadOnly ?
          "All caught up — no unread stories." : "No stories matched your filters.";
      } else {
        statusEl.textContent = "";
      }
    }

    async function loadFeeds() {
      state.feeds = await api(`/api/feeds?profile_id=${state.currentProfileId}`);
      renderFeedSelect();
    }

    function renderFeedSelect() {
      const sel = el("feed");
      const cur = state.feedId;
      sel.innerHTML = `<option value="">All feeds</option>`;
      state.feeds
        .filter(f => !state.category || f.category === state.category)
        .forEach(f => {
          const o = document.createElement("option");
          o.value = f.id;
          o.textContent = `${f.title} (${f.unread_count || 0} unread)`;
          sel.appendChild(o);
        });
      sel.value = cur;
    }

    async function loadItems() {
      state.mode = "stories";
      state.offset = 0;
      state.hasMore = true;
      state.linkIndex = new Map();
      el("grid").classList.remove("hidden");
      el("healthPanel").classList.add("hidden");
      document.querySelector(".controls").classList.remove("hidden");
      el("filterToggleBtn").classList.remove("hidden");
      el("filterDrawer").setAttribute("hidden", "");
      window.scrollTo(0, 0);

      const p = new URLSearchParams();
      p.set("profile_id", state.currentProfileId);
      if (state.category) p.set("category", state.category);
      if (state.feedId) p.set("feed_id", state.feedId);
      if (state.q) p.set("q", state.q);
      if (state.unreadOnly) p.set("unread", "true");
      if (state.starredOnly) p.set("starred", "true");
      p.set("limit", state.limit.toString());
      p.set("offset", state.offset.toString());

      el("grid").classList.add("loading");
      let fetched = [];
      try {
        fetched = await api(`/api/items?${p}`);
        if (fetched.length < state.limit) {
          state.hasMore = false;
        }
      } catch(e) { console.error(e); }
      el("grid").classList.remove("loading");
      el("grid").innerHTML = "";
      state.items = fetched;
      const { toRender } = mergeChunkForDedup(fetched);
      renderItems(toRender);
      updateStatusLabel();
      await loadMeta();
    }

    async function loadMoreItems() {
      if (!state.hasMore || state.loadingMore || state.mode !== "stories") return;
      state.loadingMore = true;
      state.offset += state.limit;

      const p = new URLSearchParams();
      p.set("profile_id", state.currentProfileId);
      if (state.category) p.set("category", state.category);
      if (state.feedId) p.set("feed_id", state.feedId);
      if (state.q) p.set("q", state.q);
      if (state.unreadOnly) p.set("unread", "true");
      if (state.starredOnly) p.set("starred", "true");
      p.set("limit", state.limit.toString());
      p.set("offset", state.offset.toString());

      try {
        const nextChunk = await api(`/api/items?${p}`);
        if (nextChunk.length < state.limit) {
          state.hasMore = false;
        }
        if (nextChunk.length > 0) {
          state.items = state.items.concat(nextChunk);
          const { toRender, toUpdate } = mergeChunkForDedup(nextChunk);
          renderItems(toRender);
          // A duplicate arrived on this page for a card rendered on an
          // earlier page — refresh that card's read/star state in place.
          for (const item of toUpdate) {
            const card = el("grid").querySelector(`article[data-primary-id="${item.id}"]`);
            if (card) refreshCardState(item, card);
          }
        }
      } catch(e) { console.error(e); }
      state.loadingMore = false;
    }

    function feedInitial(feedTitle) {
      if (!feedTitle) return "?";
      const words = feedTitle.trim().split(/\s+/);
      return words.length >= 2
        ? (words[0][0] + words[1][0]).toUpperCase()
        : feedTitle.slice(0, 2).toUpperCase();
    }

    function feedPlaceholderColour(feedTitle) {
      let hash = 0;
      for (let i = 0; i < (feedTitle || "").length; i++) {
        hash = (hash * 31 + feedTitle.charCodeAt(i)) & 0xffffffff;
      }
      const hue = Math.abs(hash) % 360;
      const isLight = document.documentElement.getAttribute("data-theme") === "light";
      return isLight
        ? `hsl(${hue}, 35%, 82%)`
        : `hsl(${hue}, 28%, 22%)`;
    }

    function makePlaceholder(feedTitle) {
      const div = document.createElement("div");
      div.className = "cardImagePlaceholder";
      div.style.background = feedPlaceholderColour(feedTitle);
      const span = document.createElement("span");
      span.textContent = feedInitial(feedTitle);
      div.appendChild(span);
      return div;
    }

    function renderItems(chunk) {
      const grid = el("grid");
      chunk.forEach(item => {
        const card = document.createElement("article");
        card.className = `card ${item.is_read ? 'read' : 'unread'}`;
        card.dataset.primaryId = item.id;

        if (item.image_url) {
          const wrap = document.createElement("div");
          wrap.className = "cardImage";
          const img = document.createElement("img");
          img.src = item.image_url;
          img.alt = "";
          img.loading = "lazy";
          img.addEventListener("error", () => wrap.replaceWith(makePlaceholder(item.feed_title)));
          wrap.appendChild(img);
          card.appendChild(wrap);
        } else {
          card.appendChild(makePlaceholder(item.feed_title));
        }
        const body = document.createElement("div");
        body.className = "cardBody";
        // --- FIX 1 (frontend): safeHref wraps item.link ----------------------
        // esc() on the output of safeHref() handles the double-quote delimiter.
        // safeHref() ensures only http/https URLs reach the anchor href,
        // blocking javascript:, data:, vbscript: and other dangerous schemes
        // for items already stored in the DB before the backend fix was applied.
        // --- FEATURE 2: duplicate count badge ---------------------------------
        // When this card represents multiple feeds' copies of the same
        // article (dedup active), show how many additional sources carried it.
        const dupeCount = (item._dupes || []).length;
        const dupeBadge = dupeCount > 0
          ? `<span class="dupeTag" title="Also seen in ${dupeCount} other feed${dupeCount === 1 ? '' : 's'}">+${dupeCount}</span>`
          : '';
        // -----------------------------------------------------------------------
        body.innerHTML = `
          <div class="cardMeta">
            <span class="categoryTag">${esc(item.category)}</span>
            <span class="feedTitleTag">${esc(item.feed_title)}</span>
            ${dupeBadge}
            ${item.author ? `<span class="authorTag">by ${esc(item.author)}</span>` : ''}
            <span class="dateTag" title="Published">${fmtDate(item.published)}</span>
            <span class="fetchedTag" title="Fetched ${fmtDate(item.fetched_at)}">↓ ${fmtDate(item.fetched_at)}</span>
          </div>
          <h2 class="cardTitle"><a href="${esc(safeHref(item.link))}" target="_blank" rel="noopener">${esc(item.title)}</a></h2>
          <p class="cardTeaser">${esc(item.teaser)}</p>
          <div class="cardSummaryActions">
            <span class="iconAction starBtn" title="Toggle Star">${item.is_starred ? '★' : '☆'}</span>
            <span class="iconAction readToggleBtn" title="Toggle Read State">${item.is_read ? '🗙' : '✔'}</span>
          </div>
        `;
        // ----------------------------------------------------------------------
        card.appendChild(body);

        card.querySelector(".readToggleBtn").addEventListener("click", (e) => { e.stopPropagation(); toggleRead(item, card); });
        card.querySelector(".starBtn").addEventListener("click", (e) => { e.stopPropagation(); toggleStar(item, card); });
        card.querySelector(".cardTitle a").addEventListener("click", () => {
          if (!item.is_read) markReadInstant(item, card);
        });
        grid.appendChild(card);
      });
    }

    // Re-render a card's read/star indicators in place after its underlying
    // (merged) item state changes — used when a duplicate arrives via
    // infinite scroll and changes the merged is_read/is_starred state of an
    // already-rendered card (FEATURE 2).
    function refreshCardState(item, card) {
      card.className = `card ${item.is_read ? 'read' : 'unread'}`;
      const readBtn = card.querySelector(".readToggleBtn");
      if (readBtn) readBtn.textContent = item.is_read ? '🗙' : '✔';
      const starBtn = card.querySelector(".starBtn");
      if (starBtn) starBtn.textContent = item.is_starred ? '★' : '☆';
      const dupeCount = (item._dupes || []).length;
      const meta = card.querySelector(".cardMeta");
      if (meta) {
        const existingBadge = meta.querySelector(".dupeTag");
        if (dupeCount > 0 && !existingBadge) {
          const badge = document.createElement("span");
          badge.className = "dupeTag";
          badge.title = `Also seen in ${dupeCount} other feed${dupeCount === 1 ? '' : 's'}`;
          badge.textContent = `+${dupeCount}`;
          meta.insertBefore(badge, meta.children[2] || null);
        } else if (existingBadge) {
          existingBadge.title = `Also seen in ${dupeCount} other feed${dupeCount === 1 ? '' : 's'}`;
          existingBadge.textContent = `+${dupeCount}`;
        }
      }
      // If this card just became fully read while unreadOnly is active,
      // remove it the same way toggleRead does.
      if (state.unreadOnly && item.is_read) {
        card.remove();
        state.items = state.items.filter(i => !allIdsFor(item).includes(i.id));
        updateStatusLabel();
      }
    }

    // --- FEATURE 1: keep feed-selector unread counts in sync ----------------
    // loadMeta() refreshes category counts/totals; loadFeeds() refreshes the
    // per-feed unread counts shown in the feed <select> (and re-renders it).
    // Call both together after any action that changes read/star state.
    async function refreshCounts() {
      await Promise.all([loadMeta(), loadFeeds()]);
    }
    // ---------------------------------------------------------------------

    // --- BACKFILL: keep the view populated after read-state changes ---------
    // Marking items read removes their cards (when unreadOnly is active),
    // which can leave the view sparse or empty even though more matching
    // items exist server-side (state.hasMore). Without this, the user sees
    // "All caught up" after mark-all-read even when hundreds of unread
    // items remain unfetched. Pulls additional pages until either the view
    // has at least BACKFILL_THRESHOLD cards or the server is exhausted.
    //
    // Threshold is lower than state.limit (30) so single-item read-toggles
    // near the end of a page don't trigger an extra fetch on every click —
    // only once the view gets genuinely sparse, or after mark-all-read
    // (which can empty the view in one go).
    //
    // Checks rendered card count (not state.items.length) because with
    // dedup active a backfilled page can consist entirely of duplicates of
    // already-removed articles, growing state.items without adding visible
    // cards.
    const BACKFILL_THRESHOLD = 10;
    async function maybeBackfill() {
      while (el("grid").children.length < BACKFILL_THRESHOLD && state.hasMore && !state.loadingMore && state.mode === "stories") {
        await loadMoreItems();
      }
      updateStatusLabel();
    }
    // ---------------------------------------------------------------------

    function markReadInstant(item, card) {
      item.is_read = true;
      const ids = allIdsFor(item);
      let removed = false;
      if (state.unreadOnly) {
        card.remove();
        state.items = state.items.filter(i => !ids.includes(i.id));
        removed = true;
        updateStatusLabel();
      } else {
        card.className = "card read";
        const btn = card.querySelector(".readToggleBtn");
        if (btn) btn.textContent = '🗙';
      }
      Promise.all(ids.map(id =>
        api(`/api/items/${id}`, { method: "PATCH", body: JSON.stringify({ is_read: true }) })
      ))
        .then(() => {
          refreshCounts();
          if (removed) return maybeBackfill();
        })
        .catch(e => console.error(e));
    }

    async function toggleRead(item, card) {
      const nextState = !item.is_read;
      item.is_read = nextState;
      const ids = allIdsFor(item);
      let removed = false;
      if (state.unreadOnly && nextState) {
        card.remove();
        state.items = state.items.filter(i => !ids.includes(i.id));
        removed = true;
        updateStatusLabel();
      } else {
        card.className = `card ${nextState ? 'read' : 'unread'}`;
        card.querySelector(".readToggleBtn").textContent = nextState ? '🗙' : '✔';
      }
      try {
        await Promise.all(ids.map(id =>
          api(`/api/items/${id}`, { method: "PATCH", body: JSON.stringify({ is_read: nextState }) })
        ));
        refreshCounts();
        if (removed) await maybeBackfill();
      } catch (e) { console.error(e); }
    }

    async function toggleStar(item, card) {
      const nextState = !item.is_starred;
      const ids = allIdsFor(item);
      try {
        const results = await Promise.all(ids.map(id =>
          api(`/api/items/${id}`, { method: "PATCH", body: JSON.stringify({ is_starred: nextState }) })
        ));
        item.is_starred = results[0].is_starred;
        const btn = card.querySelector(".starBtn");
        btn.textContent = item.is_starred ? '★' : '☆';
        await refreshCounts();
      } catch (e) { console.error(e); }
    }

    const healthSort = { col: "title", dir: 1 };

    function renderHealthTable() {
      const sorted = [...state.health].sort((a, b) => {
        let av, bv;
        switch (healthSort.col) {
          case "title":    av = a.title.toLowerCase();    bv = b.title.toLowerCase();    break;
          case "category": av = a.category.toLowerCase(); bv = b.category.toLowerCase(); break;
          case "status":   av = a.status;                 bv = b.status;                 break;
          case "fetched":  av = a.last_item_fetched_at || ""; bv = b.last_item_fetched_at || ""; break;
          default:         av = ""; bv = "";
        }
        return av < bv ? -1 * healthSort.dir : av > bv ? 1 * healthSort.dir : 0;
      });

      const arrow = col => healthSort.col === col ? (healthSort.dir === 1 ? " ▲" : " ▼") : "";
      const th = (col, label) =>
        `<th class="healthSortable" data-col="${col}" style="cursor:pointer; user-select:none;">${label}${arrow(col)}</th>`;

      const panel = el("healthPanel");
      panel.innerHTML = `
        <h2 style="margin-bottom:16px; color:var(--text-main);">Feed Synchronization Diagnostics</h2>
        <table class="healthTable">
          <colgroup>
            <col class="col-title"/><col class="col-category"/><col class="col-status"/>
            <col class="col-count"/><col class="col-vol"/><col class="col-age"/>
            <col class="col-fetched"/><col class="col-actions"/>
          </colgroup>
          <thead>
            <tr>
              ${th("title",    "Stream Label")}
              ${th("category", "Category")}
              ${th("status",   "Status")}
              <th>Unread / Total</th>
              <th>Max Vol</th>
              <th>Max Age (days)</th>
              ${th("fetched",  "Latest Fetch")}
              <th>Actions</th>
            </tr>
          </thead>
          <tbody>
            ${sorted.map(f => `
              <tr class="status-${f.status}">
                <td>
                  <strong>${esc(f.title)}</strong><br/>
                  <small style="color:var(--text-muted);">${esc(f.xml_url)}</small>
                  ${f.last_error ? `<div class="errorText">${esc(f.last_error)}</div>` : ''}
                </td>
                <td>${esc(f.category)}</td>
                <td><span class="badge badge-${f.status}">${f.status}</span></td>
                <td>${f.unread_count} / ${f.item_count}</td>
                <td>${f.max_volume ?? '—'}</td>
                <td>${f.max_age_days ?? '—'}</td>
                <td>${fmtDate(f.last_item_fetched_at) || 'Never'}</td>
                <td style="white-space:nowrap;">
                  <button class="smallRefreshFeedBtn" data-id="${f.id}" title="Refresh this feed now">↻</button>
                  <button class="smallEditFeedBtn" data-id="${f.id}">Edit</button>
                  <button class="smallDeleteFeedBtn danger" data-id="${f.id}">Delete</button>
                </td>
              </tr>
            `).join('')}
          </tbody>
        </table>
      `;

      panel.querySelectorAll(".healthSortable").forEach(th => {
        th.addEventListener("click", () => {
          const col = th.dataset.col;
          if (healthSort.col === col) {
            healthSort.dir *= -1;
          } else {
            healthSort.col = col;
            healthSort.dir = 1;
          }
          renderHealthTable();
        });
      });

      wireHealthTable();
    }

    function wireHealthTable() {
      const panel = el("healthPanel");
      panel.querySelectorAll(".smallRefreshFeedBtn").forEach(b => {
        b.addEventListener("click", async () => {
          b.disabled = true; b.textContent = "…";
          try {
            await api(`/api/feeds/${b.dataset.id}/refresh`, { method: "POST" });
            showToast("Feed refresh started.");
          } catch(e) { showToast("Refresh failed."); }
          setTimeout(() => { b.disabled = false; b.textContent = "↻"; }, 3000);
        });
      });
      panel.querySelectorAll(".smallEditFeedBtn").forEach(b => {
        b.addEventListener("click", () => openEditFeedModal(Number(b.dataset.id)));
      });
      panel.querySelectorAll(".smallDeleteFeedBtn").forEach(b => {
        b.addEventListener("click", () => deleteFeed(Number(b.dataset.id)));
      });
    }

    async function showHealth() {
      state.mode = "health";
      el("grid").classList.add("hidden");
      document.querySelector(".controls").classList.add("hidden");
      closeDrawer();
      el("filterDrawer").setAttribute("hidden", "");
      el("filterToggleBtn").classList.add("hidden");
      const panel = el("healthPanel");
      panel.classList.remove("hidden");
      panel.innerHTML = "Loading parameters…";

      try {
        state.health = await api(`/api/health?profile_id=${state.currentProfileId}`);
        renderHealthTable();
      } catch(e) { panel.innerHTML = "Failed diagnostics fetch."; }
    }

    function openEditFeedModal(id) {
      const f = state.health.find(x => x.id === id);
      if (!f) return;
      const cats = [...new Set(state.health.map(x => x.category))].sort();
      el("modalTitle").textContent = "Edit Feed Settings";
      el("modalBody").innerHTML = `
        <div class="form-field" style="margin-bottom:12px;">
          <label style="display:block; margin-bottom:4px; color:var(--text-main);">Feed Name</label>
          <input type="text" id="editFeedTitle" value="${esc(f.title)}" />
        </div>
        <div class="form-field" style="margin-bottom:12px;">
          <label style="display:block; margin-bottom:4px; color:var(--text-main);">Category Assignment</label>
          <input type="text" id="editFeedCategory" value="${esc(f.category)}" list="editCategoryList" />
          <datalist id="editCategoryList">${cats.map(c => `<option value="${esc(c)}">`).join('')}</datalist>
        </div>
        <div class="form-field" style="margin-bottom:12px;">
          <label style="display:block; margin-bottom:4px; color:var(--text-main);">XML Endpoint Address</label>
          <input type="url" id="editFeedXmlUrl" value="${esc(f.xml_url)}" />
        </div>
        <div class="form-field" style="margin-bottom:12px;">
          <label style="display:block; margin-bottom:4px; color:var(--text-main);">Homepage Web Address</label>
          <input type="url" id="editFeedHtmlUrl" value="${esc(f.html_url)}" />
        </div>
        <div style="display:grid; grid-template-columns:1fr 1fr; gap:12px;">
          <div class="form-field">
            <label style="display:block; margin-bottom:4px; color:var(--text-main);">Max volume <small style="color:var(--text-muted);">(items per fetch)</small></label>
            <input type="number" id="editFeedMaxVolume" value="${f.max_volume ?? ''}" placeholder="Default (${100})" min="1" max="500" />
          </div>
          <div class="form-field">
            <label style="display:block; margin-bottom:4px; color:var(--text-main);">Max age <small style="color:var(--text-muted);">(days before pruning)</small></label>
            <input type="number" id="editFeedMaxAge" value="${f.max_age_days ?? ''}" placeholder="Default (90)" min="1" max="3650" />
          </div>
        </div>
      `;

      const saveBtn = el("modalSaveBtn");
      const clone = saveBtn.cloneNode(true);
      saveBtn.parentNode.replaceChild(clone, saveBtn);

      clone.addEventListener("click", async () => {
        const maxVol = el("editFeedMaxVolume").value;
        const maxAge = el("editFeedMaxAge").value;
        const payload = {
          title:        el("editFeedTitle").value.trim(),
          category:     el("editFeedCategory").value.trim(),
          xml_url:      el("editFeedXmlUrl").value.trim(),
          html_url:     el("editFeedHtmlUrl").value.trim(),
          max_volume:   maxVol ? parseInt(maxVol) : null,
          max_age_days: maxAge ? parseInt(maxAge) : null,
        };
        if (!payload.title || !payload.category || !payload.xml_url) return alert("Fill required fields.");
        try {
          await api(`/api/feeds/${id}`, { method: "PUT", body: JSON.stringify(payload) });
          closeModal();
          showHealth();
          loadMeta();
        } catch(e) { alert(e); }
      });

      el("editModal").classList.remove("hidden");
    }

    async function deleteFeed(id) {
      if (!confirm("Confirm complete feed metadata and matching stories drop?")) return;
      try {
        await api(`/api/feeds/${id}`, { method: "DELETE" });
        showHealth();
        loadMeta();
      } catch(e) { alert(e); }
    }

    function showManageFeeds() {
      state.mode = "manage";
      el("grid").classList.add("hidden");
      document.querySelector(".controls").classList.add("hidden");
      closeDrawer();
      el("filterDrawer").setAttribute("hidden", "");
      el("filterToggleBtn").classList.add("hidden");
      const panel = el("healthPanel");
      panel.classList.remove("hidden");

      panel.innerHTML = `
        <div style="max-width: 600px; margin: 0 auto; background:var(--bg-card); padding:24px; border-radius:8px; border:1px solid var(--border-color);">
          <h2 style="margin-bottom:20px; color:var(--text-main);">Feed Management Control</h2>
          
          <div style="padding-bottom:20px; margin-bottom:20px; border-bottom:1px dashed var(--border-color);">
            <h3 style="margin-bottom:12px; font-size:1.1rem; color:var(--text-main);">Switch / Generate Dynamic Profile</h3>
            <div style="display:flex; gap:10px; margin-bottom:10px;">
              <select id="manageProfileDropdown" style="flex:1; padding:8px; background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); border-radius:6px;"></select>
              <button id="switchToProfileBtn">Switch Context</button>
            </div>
            <div style="display:flex; gap:10px;">
              <input type="text" id="newProfileName" placeholder="New profile token ID..." style="flex:1; padding:8px; background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); border-radius:6px;" />
              <button id="createProfileBtn" class="secondary">Add Profile</button>
            </div>
          </div>

          <div>
            <h3 style="margin-bottom:12px; font-size:1.1rem; color:var(--text-main);">Register New Subscription Target</h3>
            <div style="display:grid; grid-template-columns:1fr; gap:12px; margin-bottom:16px;">
              <input type="text" id="addFeedTitle" placeholder="Custom feed shorthand title (e.g. Wired Security)" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
              <input type="text" id="addFeedCategory" placeholder="Category (e.g. Security)" list="addCategoryList" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
              <datalist id="addCategoryList">${state.meta ? state.meta.categories.map(c => `<option value="${esc(c.category)}">`).join('') : ''}</datalist>
              <input type="url" id="addFeedXmlUrl" placeholder="Direct link RSS/Atom XML endpoint" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
              <input type="url" id="addFeedHtmlUrl" placeholder="Optional standard website homepage URL" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
              <div style="display:grid; grid-template-columns:1fr 1fr; gap:12px;">
                <input type="number" id="addFeedMaxVolume" placeholder="Max volume (default 100)" min="1" max="500" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
                <input type="number" id="addFeedMaxAge" placeholder="Max age days (default 90)" min="1" max="3650" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
              </div>
            </div>
            <button id="submitNewFeedBtn" style="width:100%; padding:10px;">Register Stream Instance</button>
          </div>

          <div style="padding-top:20px; margin-top:4px; border-top:1px dashed var(--border-color);">
            <h3 style="margin-bottom:12px; font-size:1.1rem; color:var(--text-main);">OPML Import / Export</h3>
            <div style="display:flex; align-items:center; flex-wrap:wrap; gap:12px; background:var(--bg-app); padding:14px; border-radius:6px; border:1px solid var(--border-color);">
              <div style="display:flex; flex-direction:column; gap:4px;">
                <span style="font-size:0.8rem; font-weight:bold; color:var(--text-muted);">Import OPML file:</span>
                <input type="file" id="opmlFileInput" accept=".opml,.xml" style="font-size:0.85rem; min-height:auto; padding:4px; background:transparent; border:none; color:var(--text-muted);" />
              </div>
              <button id="importOpmlBtn" class="secondary" style="padding:8px 14px;">Upload &amp; Merge</button>
              <div style="margin-left:auto; display:flex; flex-direction:column; gap:4px; align-items:flex-end;">
                <span style="font-size:0.8rem; font-weight:bold; color:var(--text-muted);">Backup feeds:</span>
                <button id="exportOpmlBtn" class="secondary" style="padding:8px 14px;">Download OPML</button>
              </div>
            </div>
          </div>

          <div style="padding-top:20px; margin-top:4px; border-top:1px dashed var(--border-color);">
            <h3 style="margin-bottom:12px; font-size:1.1rem; color:var(--text-main);">Database Maintenance</h3>
            <div style="display:flex; align-items:center; gap:12px; background:var(--bg-app); padding:14px; border-radius:6px; border:1px solid var(--border-color);">
              <div style="flex:1; font-size:0.85rem; color:var(--text-muted);">Remove read, unstarred items beyond each feed's max age (default 90 days). Uses ingestion timestamp, not article date.</div>
              <button id="pruneNowBtn" class="secondary" style="padding:8px 14px; white-space:nowrap;">Prune now</button>
            </div>
          </div>
        </div>
      `;

      const profSel = el("manageProfileDropdown");
      profSel.innerHTML = "";
      state.profiles.forEach(p => {
        const o = document.createElement("option");
        o.value = p.id;
        o.textContent = p.name;
        profSel.appendChild(o);
      });
      profSel.value = state.currentProfileId;

      el("switchToProfileBtn").addEventListener("click", async () => {
        state.currentProfileId = Number(profSel.value);
        await initApplicationContext();
        showManageFeeds();
      });

      el("createProfileBtn").addEventListener("click", async () => {
        const name = el("newProfileName").value.trim();
        if (!name) return;
        try {
          const res = await api("/api/profiles", { method: "POST", body: JSON.stringify({ name }) });
          state.currentProfileId = res.id;
          await loadProfiles();
          await initApplicationContext();
          showManageFeeds();
        } catch(e) { alert(e); }
      });

      el("submitNewFeedBtn").addEventListener("click", async () => {
        const maxVol = el("addFeedMaxVolume").value;
        const maxAge = el("addFeedMaxAge").value;
        const payload = {
          title:        el("addFeedTitle").value.trim(),
          category:     el("addFeedCategory").value.trim(),
          xml_url:      el("addFeedXmlUrl").value.trim(),
          html_url:     el("addFeedHtmlUrl").value.trim(),
          max_volume:   maxVol ? parseInt(maxVol) : null,
          max_age_days: maxAge ? parseInt(maxAge) : null,
        };
        if (!payload.title || !payload.category || !payload.xml_url) return alert("Fill core subscription parameters.");
        try {
          await api(`/api/feeds?profile_id=${state.currentProfileId}`, { method: "POST", body: JSON.stringify(payload) });
          alert("Feed registered!");
          el("addFeedTitle").value = "";
          el("addFeedCategory").value = "";
          el("addFeedXmlUrl").value = "";
          el("addFeedHtmlUrl").value = "";
          el("addFeedMaxVolume").value = "";
          el("addFeedMaxAge").value = "";
          await loadMeta();
          await loadFeeds();
        } catch(e) { alert(e); }
      });

      el("pruneNowBtn").addEventListener("click", async () => {
        const btn = el("pruneNowBtn");
        btn.disabled = true; btn.textContent = "Pruning…";
        try {
          const res = await api(`/api/prune?profile_id=${state.currentProfileId}`, { method: "POST" });
          showToast(`Pruned ${res.deleted} item${res.deleted !== 1 ? 's' : ''}.`);
          await loadMeta();
        } catch(e) { showToast("Prune failed."); }
        btn.disabled = false; btn.textContent = "Prune now";
      });

      el("importOpmlBtn").addEventListener("click", async () => {
        const fileInput = el("opmlFileInput");
        if (!fileInput.files.length) return alert("Select an OPML file first.");
        const formData = new FormData();
        formData.append("file", fileInput.files[0]);
        try {
          const response = await fetch(`/api/profiles/${state.currentProfileId}/import`, { method: "POST", body: formData });
          if (!response.ok) throw new Error(await response.text());
          const res = await response.json();
          alert(`Import complete.\nFeeds found: ${res.total_found}\nNewly added: ${res.newly_added}`);
          await loadMeta();
          await loadFeeds();
          showManageFeeds();
        } catch(e) { alert(`Import failed: ${e.message}`); }
      });

      el("exportOpmlBtn").addEventListener("click", () => {
        window.location.href = `/api/profiles/${state.currentProfileId}/export`;
      });
    }

    function closeModal() { el("editModal").classList.add("hidden"); }

    async function initApplicationContext() {
      await loadMeta();
      await loadFeeds();
      if (state.mode === "stories") await loadItems();
    }

    el("homeBtn").addEventListener("click", () => {
      state.category = ""; state.feedId = ""; state.q = "";
      el("category").value = ""; el("feed").value = ""; el("search").value = "";
      state.mode = "stories";
      initApplicationContext();
    });

    el("stats").addEventListener("click", () => {
      if (state.meta && state.meta.error_count > 0) showHealth();
    });

    el("category").addEventListener("change", e => {
      state.category = e.target.value;
      state.feedId = "";
      renderFeedSelect();
      loadItems();
      syncDrawerToState();
    });

    el("feed").addEventListener("change", e => {
      state.feedId = e.target.value;
      loadItems();
      syncDrawerToState();
    });

    let searchTimeout;
    el("search").addEventListener("input", e => {
      clearTimeout(searchTimeout);
      searchTimeout = setTimeout(() => {
        state.q = e.target.value.trim();
        loadItems();
        syncDrawerToState();
      }, 250);
    });

    el("unreadOnly").addEventListener("change", e => { state.unreadOnly = e.target.checked; loadItems(); syncDrawerToState(); });
    el("starredOnly").addEventListener("change", e => { state.starredOnly = e.target.checked; loadItems(); syncDrawerToState(); });

    el("healthBtn").addEventListener("click", showHealth);

    (function initTheme() {
      const apply = (theme) => {
        if (theme === "light") {
          document.documentElement.setAttribute("data-theme", "light");
        } else {
          document.documentElement.removeAttribute("data-theme");
        }
      };
      apply(localStorage.getItem("lf-theme") || "dark");
      const toggle = () => {
        const next = document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light";
        localStorage.setItem("lf-theme", next);
        apply(next);
      };
      el("themeToggleBtn").addEventListener("click", toggle);
      el("themeToggleBtnMobile").addEventListener("click", toggle);
    })();

    // --- DENSITY TOGGLE: compact card layout for phone widths ---------------
    // Mobile-only (<767px) alternative card layout — small thumbnail beside
    // a 1-line title + 1-line teaser instead of the full-width image and
    // multi-line card. Pure CSS reflow of the same renderItems() markup via
    // [data-density="compact"] selectors, scoped under the existing mobile
    // breakpoint — desktop is unaffected regardless of this setting.
    (function initDensity() {
      const btn = el("densityToggleBtnMobile");
      if (!btn) return;
      const apply = (density) => {
        if (density === "compact") {
          document.documentElement.setAttribute("data-density", "compact");
        } else {
          document.documentElement.removeAttribute("data-density");
        }
      };
      apply(localStorage.getItem("lf-density") || "comfortable");
      btn.addEventListener("click", () => {
        const next = document.documentElement.getAttribute("data-density") === "compact" ? "comfortable" : "compact";
        localStorage.setItem("lf-density", next);
        apply(next);
      });
    })();
    // ---------------------------------------------------------------------

    el("homeBtnMobile").addEventListener("click", () => {
      state.category = ""; state.feedId = ""; state.q = "";
      el("category").value = ""; el("feed").value = ""; el("search").value = "";
      state.mode = "stories";
      initApplicationContext();
    });
    el("statsMobile").addEventListener("click", () => {
      if (state.meta && state.meta.error_count > 0) showHealth();
    });
    el("markReadBtnMobile").addEventListener("click", () => el("markReadBtn").click());
    el("refreshBtnMobile").addEventListener("click", () => el("refreshBtn").click());
    el("filterToggleBtnMobile").addEventListener("click", () => el("filterToggleBtn").click());
    el("manageFeedsBtn").addEventListener("click", showManageFeeds);

    el("markReadBtn").addEventListener("click", async () => {
      const unread = state.items.filter(i => !i.is_read);
      if (!unread.length) return;
      showToast("Marking items read…", 0);
      const results = await Promise.allSettled(
        unread.map(i => api(`/api/items/${i.id}`, { method: "PATCH", body: JSON.stringify({ is_read: true }) }))
      );
      results.forEach((result, idx) => {
        if (result.status === "fulfilled") {
          unread[idx].is_read = true;
        }
      });
      const nowRead = unread.filter(i => i.is_read);
      const nowReadIds = new Set(nowRead.map(i => i.id));
      let removed = false;
      if (state.unreadOnly) {
        el("grid").querySelectorAll("article.card.unread").forEach(c => c.remove());
        state.items = state.items.filter(i => !nowReadIds.has(i.id));
        removed = true;
      } else {
        el("grid").querySelectorAll("article.card.unread").forEach(c => c.classList.replace("unread", "read"));
      }
      if (removed) {
        // Re-fetch from offset 0 so the next page of unread items isn't
        // skipped. maybeBackfill() would increment the stale offset and
        // request e.g. offset=60 of the *new* unread set, silently skipping
        // items 0-59 that were never shown. loadItems() resets the cursor.
        await loadItems();
        refreshCounts(); // loadItems() calls loadMeta() but not loadFeeds(); need both to update feed-selector unread counts
      } else {
        updateStatusLabel();
        refreshCounts();
      }
      showToast(`Marked ${nowRead.length} item${nowRead.length !== 1 ? 's' : ''} read.`);
    });

    function showToast(msg, durationMs = 3000) {
      const t = el("toast");
      el("toastMsg").textContent = msg;
      el("toastActions").classList.add("hidden");
      t.classList.remove("hidden");
      clearTimeout(showToast._timer);
      if (durationMs > 0) {
        showToast._timer = setTimeout(() => t.classList.add("hidden"), durationMs);
      }
    }

    function showActionToast(msg, onReload, autoDismissMs = 30000) {
      const t = el("toast");
      el("toastMsg").textContent = msg;
      el("toastActions").classList.remove("hidden");
      t.classList.remove("hidden");
      clearTimeout(showToast._timer);

      const cleanup = () => {
        t.classList.add("hidden");
        el("toastActions").classList.add("hidden");
        clearTimeout(showToast._timer);
      };

      el("toastReloadBtn").onclick = () => { cleanup(); onReload(); };
      el("toastDismissBtn").onclick = cleanup;
      showToast._timer = setTimeout(cleanup, autoDismissMs);
    }

    el("refreshBtn").addEventListener("click", async () => {
      const btn = el("refreshBtn");
      const mobBtn = el("refreshBtnMobile");
      if (btn.disabled) return;
      btn.disabled = true;
      mobBtn.style.opacity = "0.4";
      try {
        await api("/api/refresh", { method: "POST" });
      } catch(e) {
        if (e.message && e.message.includes("429")) {
          showToast("Refresh already in progress.", 3000);
        } else {
          showToast("Refresh failed.", 3000);
        }
        btn.disabled = false;
        mobBtn.style.opacity = "";
        return;
      }

      showToast("Refreshing feeds…", 0);

      const pollInterval = setInterval(async () => {
        try {
          const s = await api("/api/refresh/status");
          if (s.status === "idle") {
            clearInterval(pollInterval);
            btn.disabled = false;
            mobBtn.style.opacity = "";
            showActionToast(
              "Refresh complete — reload articles?",
              () => { if (state.mode === "stories") initApplicationContext(); },
              30000
            );
          }
        } catch(e) {
          clearInterval(pollInterval);
          btn.disabled = false;
          mobBtn.style.opacity = "";
          showToast("Could not confirm refresh status.", 3000);
        }
      }, 2000);
    });

    el("profileSelect").addEventListener("change", e => {
      state.currentProfileId = Number(e.target.value);
      state.category = ""; state.feedId = "";
      initApplicationContext();
    });

    function openDrawer() {
      el("filterDrawer").removeAttribute("hidden");
      el("filterDrawer").classList.add("open");
      el("filterDrawerOverlay").classList.add("open");
      el("filterToggleBtn").setAttribute("aria-expanded", "true");
    }
    function closeDrawer() {
      el("filterDrawer").classList.remove("open");
      el("filterDrawerOverlay").classList.remove("open");
      el("filterToggleBtn").setAttribute("aria-expanded", "false");
    }
    el("filterToggleBtn").addEventListener("click", () => {
      el("filterDrawer").hasAttribute("hidden")
        ? (el("filterDrawer").removeAttribute("hidden"), requestAnimationFrame(() => openDrawer()))
        : (el("filterDrawer").classList.contains("open") ? closeDrawer() : openDrawer());
    });
    el("filterDrawerOverlay").addEventListener("click", closeDrawer);

    function syncDrawerToState() {
      el("profileSelectDrawer").value = state.currentProfileId;
      el("categoryDrawer").value = state.category;
      el("feedDrawer").value = state.feedId;
      el("searchDrawer").value = state.q;
      el("unreadOnlyDrawer").checked = state.unreadOnly;
      el("starredOnlyDrawer").checked = state.starredOnly;
      const active = state.category || state.feedId || state.q || state.starredOnly || !state.unreadOnly;
      el("filterToggleBtn").classList.toggle("filterActiveDot", !!active);
      const mob = el("filterToggleBtnMobile");
      if (mob) mob.classList.toggle("active", !!active);
    }

    function syncDrawerOptions() {
      ["categoryDrawer", "feedDrawer", "profileSelectDrawer"].forEach(drawerId => {
        const srcId = drawerId.replace("Drawer", "").replace("profileSelectDrawer","profileSelect");
        const src = el(srcId === "profileSelectDrawer" ? "profileSelect" : srcId);
        if (!src) return;
        const dst = el(drawerId);
        dst.innerHTML = src.innerHTML;
      });
      syncDrawerToState();
    }

    el("profileSelectDrawer").addEventListener("change", e => {
      state.currentProfileId = Number(e.target.value);
      state.category = ""; state.feedId = "";
      closeDrawer();
      initApplicationContext();
    });
    el("categoryDrawer").addEventListener("change", e => {
      state.category = e.target.value; state.feedId = "";
      el("category").value = state.category;
      loadItems(); syncDrawerToState(); closeDrawer();
    });
    el("feedDrawer").addEventListener("change", e => {
      state.feedId = e.target.value;
      el("feed").value = state.feedId;
      loadItems(); syncDrawerToState(); closeDrawer();
    });
    let drawerSearchTimer;
    el("searchDrawer").addEventListener("input", e => {
      clearTimeout(drawerSearchTimer);
      drawerSearchTimer = setTimeout(() => {
        state.q = e.target.value;
        el("search").value = state.q;
        loadItems(); syncDrawerToState();
      }, 350);
    });
    el("unreadOnlyDrawer").addEventListener("change", e => {
      state.unreadOnly = e.target.checked;
      el("unreadOnly").checked = state.unreadOnly;
      loadItems(); syncDrawerToState();
    });
    el("starredOnlyDrawer").addEventListener("change", e => {
      state.starredOnly = e.target.checked;
      el("starredOnly").checked = state.starredOnly;
      loadItems(); syncDrawerToState();
    });

    const _origLoadFeeds = loadFeeds;
    loadFeeds = async function() {
      await _origLoadFeeds();
      syncDrawerOptions();
    };

    el("modalCancelBtn").addEventListener("click", closeModal);

    window.addEventListener("scroll", () => {
      // Guard: scrollY > 0 prevents the programmatic window.scrollTo(0,0)
      // in loadItems() from firing this handler. On mobile the page can be
      // shorter than the viewport immediately after a fresh load, making the
      // threshold condition true at scrollY=0 and auto-consuming extra pages.
      if (window.scrollY > 0 &&
          (window.innerHeight + window.scrollY) >= document.documentElement.scrollHeight - 150) {
        loadMoreItems();
      }
    });

    (async () => {
      await loadProfiles();
      await initApplicationContext();
    })();
  </script>
</body>
</html>

FRONTENDHTML

# ===================================================================
# app/static/styles.css — unchanged from original (no security fixes
# applied here; included for completeness so a full re-deploy is
# self-contained)
# ===================================================================
write_file "app/static/styles.css" "stylesheet" << 'CUSTOMCSS'
:root {
  --primary: #1A5C63;
  --primary-hover: #14474d;
  --bg-app: #0f172a;
  --bg-card: #1e293b;
  --bg-hover: #2d3f55;
  --border-color: #334155;
  --text-main: #f8fafc;
  --text-muted: #94a3b8;
  --tag-bg: #1e3a8a;
  --tag-color: #93c5fd;
  --placeholder-text: rgba(255,255,255,0.18);
  --radius: 8px;
  color-scheme: dark;
}

[data-theme="light"] {
  --bg-app: #f1f5f9;
  --bg-card: #ffffff;
  --bg-hover: #e2e8f0;
  --border-color: #e2e8f0;
  --text-main: #0f172a;
  --text-muted: #64748b;
  --tag-bg: #dbeafe;
  --tag-color: #1e40af;
  --placeholder-text: rgba(0,0,0,0.12);
  color-scheme: light;
}

* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

body {
  background-color: var(--bg-app);
  color: var(--text-main);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  line-height: 1.4;
  padding-top: 0;
}

.hero {
  display: flex;
  flex-direction: column;
  gap: 16px;
  padding: 16px;
  background: var(--bg-card);
  border-bottom: 1px solid var(--border-color);
}

.heroTitle h1 {
  font-size: 1.4rem;
  font-weight: 800;
  cursor: pointer;
}

.muted {
  color: var(--text-muted);
  font-size: 0.8rem;
}

.heroActions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}

@media (min-width: 768px) {
  .hero {
    flex-direction: row;
    justify-content: space-between;
    align-items: center;
    padding: 20px 32px;
  }
}

.controls {
  display: grid;
  grid-template-columns: 1fr;
  gap: 10px;
  padding: 16px;
}

@media (min-width: 480px) {
  .controls { grid-template-columns: repeat(2, 1fr); }
  #search { grid-column: span 2; }
}

@media (min-width: 1024px) {
  .controls {
    grid-template-columns: auto 2fr repeat(2, 1fr) auto auto;
    align-items: center;
  }
  #search { grid-column: span 1; }
}

.mobileBar { display: none; }

@media (max-width: 767px) {
  .hero .heroTitle { display: none; }
  .hero .heroActions { display: none; }
  .hero { padding: 0; min-height: 0; border-bottom: none; }

  .mobileBar {
    display: flex;
    align-items: center;
    position: sticky;
    top: 0;
    z-index: 100;
    background: var(--bg-card);
    border-bottom: 1px solid var(--border-color);
    padding: 0 8px;
    height: 52px;
    gap: 2px;
  }

  main { padding-top: 0; }
}

/* mobileBar child styles live outside the breakpoint so the phone-landscape
   rule below can enable the bar without duplicating all these declarations. */
.mobileBarBrand {
  all: unset;
  display: flex;
  align-items: center;
  justify-content: flex-start;
  padding: 0 4px 0 8px;
  height: 44px;
  color: var(--primary);
  cursor: pointer;
  flex-shrink: 0;
  font-size: 1.05rem;
  font-weight: 800;
  letter-spacing: -0.01em;
  white-space: nowrap;
}

.mobileBarStats {
  all: unset;
  font-size: 0.72rem;
  color: var(--text-muted);
  display: flex;
  gap: 8px;
  align-items: center;
  cursor: pointer;
  padding: 0 4px;
  white-space: nowrap;
}

.mobileBarSpacer { flex: 1; }

.mobileBarBtn {
  all: unset;
  display: flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 44px;
  color: var(--text-muted);
  cursor: pointer;
  border-radius: var(--radius);
  flex-shrink: 0;
  transition: color 0.15s, background 0.15s;
}
.mobileBarBtn:active { background: var(--border-color); color: var(--text-main); }
.mobileBarBtn svg { width: 22px; height: 22px; }
.mobileBarBtn.active { color: var(--primary); }

.iconMoon { display: none; }
.iconSun  { display: block; }
[data-theme="light"] .iconMoon { display: block; }
[data-theme="light"] .iconSun  { display: none; }

/* Icon shows the destination state, not the current state */
.iconCompact     { display: block; }
.iconComfortable { display: none; }
[data-density="compact"] .iconCompact     { display: none; }
[data-density="compact"] .iconComfortable { display: block; }

.heroIconBtn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 44px;
  height: 44px;
  padding: 0;
  border-radius: var(--radius);
  flex-shrink: 0;
}
.heroIconBtn svg { width: 22px; height: 22px; }

.heroIconBtn .iconMoon { display: none; }
.heroIconBtn .iconSun  { display: block; }
[data-theme="light"] .heroIconBtn .iconMoon { display: block; }
[data-theme="light"] .heroIconBtn .iconSun  { display: none; }

.themeToggleBtn {
  font-size: 1.1rem;
  padding: 6px 10px !important;
  min-width: 40px;
  line-height: 1;
}

.controls input,
.controls select,
.filterDrawerRow select,
#searchDrawer {
  background: var(--bg-app) !important;
  color: var(--text-main) !important;
  border-color: var(--border-color) !important;
}
.controls input, 
.controls select,
.heroActions button,
.modal-actions button,
.smallEditFeedBtn, .smallDeleteFeedBtn,
button {
  min-height: 44px;
  padding: 10px 14px;
  border-radius: var(--radius);
  border: 1px solid var(--border-color);
  background: var(--bg-card);
  font-size: 16px; 
  color: var(--text-main);
  cursor: pointer;
  font-weight: 500;
}

button {
  background: var(--primary);
  border: none;
}
button:hover { background: var(--primary-hover); }

button.secondary {
  background: var(--bg-card);
  border: 1px solid var(--border-color);
}
button.secondary:hover { background: var(--bg-hover); }

.toggle {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-height: 44px;
  cursor: pointer;
  font-size: 14px;
}
.toggle input { width: 18px; height: 18px; }

.grid {
  display: grid;
  grid-template-columns: 1fr;
  grid-auto-rows: 1fr;
  gap: 16px;
  padding: 16px;
  align-items: stretch;
}

@media (min-width: 640px) { .grid { grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); } }

/* Tablet range (640–1023px): reduce card image height ~30% so tiles
   don't loom too large between the mobile and full desktop breakpoints. */
@media (min-width: 640px) and (max-width: 1023px) {
  .cardImage img,
  .cardImagePlaceholder { height: 112px; }
}

.card {
  display: flex;
  flex-direction: column;
  background: var(--bg-card);
  border-radius: var(--radius);
  border: 1px solid var(--border-color);
  overflow: hidden;
  height: 100%;
}

@media (max-width: 480px) {
  .grid { padding: 8px 0; gap: 10px; }
  .card { border-radius: 0; border-left: none; border-right: none; }
}

.card.read { opacity: 0.45; }
.card.unread { border-left: 3px solid var(--primary); }

.cardImage img {
  width: 100%;
  height: 160px;
  object-fit: cover;
  display: block;
  flex-shrink: 0;
}

.cardImagePlaceholder {
  width: 100%;
  height: 160px;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  user-select: none;
}

.cardImagePlaceholder span {
  font-size: 2.4rem;
  font-weight: 800;
  letter-spacing: -0.02em;
  color: var(--placeholder-text);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
}

.cardBody {
  padding: 14px;
  display: flex;
  flex-direction: column;
  flex: 1;
  min-height: 0;
}

.cardMeta {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 6px;
  font-size: 0.75rem;
  color: var(--text-muted);
  margin-bottom: 8px;
  flex-shrink: 0;
}
.categoryTag { background: var(--tag-bg); color: var(--tag-color); padding: 2px 6px; border-radius: 4px; font-weight: 600; }
.feedTitleTag { color: var(--text-main); font-weight: 600; }
.fetchedTag { color: var(--text-muted); font-size: 0.7rem; font-style: italic; }
/* FEATURE 2: badge showing an article was also seen in other feeds (dedup) */
.dupeTag { background: var(--bg-hover); color: var(--text-muted); padding: 2px 6px; border-radius: 4px; font-weight: 600; font-size: 0.7rem; }

.cardTitle {
  font-size: 1.05rem;
  font-weight: 700;
  margin-bottom: 6px;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
  flex-shrink: 0;
}
.cardTitle a { color: var(--text-main); text-decoration: none; }
.cardTitle a:hover { color: var(--primary); }

.cardTeaser {
  font-size: 0.88rem;
  color: var(--text-muted);
  margin-bottom: 12px;
  display: -webkit-box;
  -webkit-line-clamp: 3;
  -webkit-box-orient: vertical;
  overflow: hidden;
  flex: 1;
}

.cardSummaryActions {
  display: flex;
  gap: 16px;
  margin-top: auto;
  padding-top: 10px;
  border-top: 1px solid var(--border-color);
}

.iconAction {
  font-size: 1.25rem;
  cursor: pointer;
  user-select: none;
  min-height: 44px;
  min-width: 44px;
  display: inline-flex;
  align-items: center;
  justify-content: center;
  color: var(--text-muted);
  transition: color 0.1s ease;
}
.iconAction:hover { color: var(--text-main); }
.starBtn { color: #eab308 !important; }

/* ----------------------------------------------------------------------
   DENSITY: compact card layout (mobile only, <767px)
   Grid layout: 56px thumb | 1fr text | 68px actions
   Row 1: thumb (spans rows 1-2) | title  | actions (spans rows 1-2)
   Row 2:                        | meta   |
   Row 3: teaser spans all three columns (flows under the thumbnail)

   .cardBody is set to display:contents so its children become direct
   grid children and cardTeaser can be placed on its own spanning row.
   No markup changes — pure CSS reflow.
---------------------------------------------------------------------- */
@media (max-width: 767px) {
  [data-density="compact"] .grid {
    gap: 1px;
    padding: 0;
  }

  [data-density="compact"] .card {
    display: grid;
    grid-template-columns: 56px 1fr 68px;
    grid-template-rows: auto auto auto;
    column-gap: 8px;
    row-gap: 2px;
    padding: 8px 12px;
    height: auto;
    border-left: none;
    border-radius: 0;
    border-bottom: 1px solid var(--border-color);
  }
  [data-density="compact"] .card.unread {
    border-left: 3px solid var(--primary);
    padding-left: 9px;
  }

  [data-density="compact"] .cardImage,
  [data-density="compact"] .cardImagePlaceholder {
    grid-column: 1;
    grid-row: 1 / 3;
    width: 56px;
    height: 56px;
    border-radius: 6px;
    align-self: start;
  }
  [data-density="compact"] .cardImage img { width: 56px; height: 56px; }
  [data-density="compact"] .cardImagePlaceholder span { font-size: 1rem; }

  /* Dissolve cardBody into the card grid — children become direct grid
     items so cardTeaser can span the full card width on its own row. */
  [data-density="compact"] .cardBody {
    display: contents;
  }

  [data-density="compact"] .cardTitle {
    grid-column: 2;
    grid-row: 1;
    align-self: end;
    font-size: 0.92rem;
    margin-bottom: 0;
    -webkit-line-clamp: 2;
    order: unset;
  }

  [data-density="compact"] .cardMeta {
    grid-column: 2;
    grid-row: 2;
    align-self: start;
    margin-bottom: 0;
    font-size: 0.68rem;
    order: unset;
  }
  [data-density="compact"] .fetchedTag,
  [data-density="compact"] .authorTag {
    display: none;
  }

  /* Teaser spans all columns — flows under both thumb and text */
  [data-density="compact"] .cardTeaser {
    grid-column: 1 / -1;
    grid-row: 3;
    font-size: 0.78rem;
    margin: 0;
    margin-top: 4px;
    padding-top: 5px;
    border-top: 1px solid var(--border-color);
    -webkit-line-clamp: 2;
    flex: none;
    order: unset;
  }

  /* Actions column: centered beside the thumb+text rows */
  [data-density="compact"] .cardSummaryActions {
    grid-column: 3;
    grid-row: 1 / 3;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 4px;
    position: static;
    transform: none;
    border-top: none;
    margin-top: 0;
    padding-top: 0;
  }
  [data-density="compact"] .iconAction {
    min-height: 36px;
    min-width: 36px;
    font-size: 1.05rem;
  }
}
/* ------------------------------------------------------------------- */

.healthPanel { padding: 16px; background: var(--bg-card); margin: 16px; border-radius: var(--radius); border: 1px solid var(--border-color); overflow-x: auto; }
.healthTable { width: 100%; border-collapse: collapse; font-size: 0.9rem; color:var(--text-main); table-layout: fixed; }
.healthTable th, .healthTable td { padding: 10px 12px; border-bottom: 1px solid #334155; vertical-align: top; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.healthTable th { background: var(--bg-app); text-align: left; font-weight: 600; font-size: 0.78rem; color: var(--text-muted); letter-spacing: 0.03em; white-space: nowrap; }
.healthTable td:first-child { white-space: normal; }
.healthTable col.col-title    { width: 28%; }
.healthTable col.col-category { width: 10%; }
.healthTable col.col-status   { width: 8%; }
.healthTable col.col-count    { width: 9%; }
.healthTable col.col-vol      { width: 7%; }
.healthTable col.col-age      { width: 9%; }
.healthTable col.col-fetched  { width: 14%; }
.healthTable col.col-actions  { width: 15%; }
.healthTable th.healthSortable:hover { color: var(--text-main); background: var(--bg-hover); }
.healthTable tbody tr:hover { background: var(--bg-hover); }
.errorText { color: #ef4444; font-size: 0.8rem; margin-top: 4px; font-family: monospace; }
.badge { display: inline-block; padding: 2px 6px; font-size: 0.7rem; font-weight: 600; border-radius: 4px; }
.badge-error   { background: #7f1d1d; color: #fca5a5; }
.badge-healthy { background: #14532d; color: #86efac; }
.badge-never_checked { background: var(--bg-hover); color: var(--text-muted); }
[data-theme="light"] .badge-error   { background: #fee2e2; color: #991b1b; }
[data-theme="light"] .badge-healthy { background: #dcfce7; color: #166534; }

.modal { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.7); display: flex; align-items: center; justify-content: center; z-index: 2000; padding: 16px; }
.modal-content { background: var(--bg-card); padding: 24px; border-radius: var(--radius); width: 100%; max-width: 500px; border: 1px solid var(--border-color); }
.modal input { width: 100%; background: var(--bg-app); color: var(--text-main); border: 1px solid var(--border-color); padding: 10px; border-radius: 6px; margin-top: 4px; }
.filterToggleBtn { display: none; }

@media (max-width: 767px) {
  .controls { display: none !important; }
  .filterToggleBtn { display: inline-flex !important; align-items: center; gap: 6px; }

  .filterDrawer {
    position: fixed;
    bottom: 0; left: 0; right: 0;
    z-index: 200;
    background: var(--bg-card);
    border-top: 2px solid #1A5C63;
    border-radius: 14px 14px 0 0;
    transform: translateY(100%);
    transition: transform 0.28s cubic-bezier(0.32, 0.72, 0, 1);
    max-height: 80vh;
    overflow-y: auto;
  }
  .filterDrawer.open {
    transform: translateY(0);
  }
  .filterDrawerInner {
    padding: 12px 16px 32px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }
  .filterDrawerHandle {
    width: 36px; height: 4px;
    background: var(--border-color);
    border-radius: 2px;
    margin: 0 auto 4px;
  }
  .filterDrawerRow {
    display: flex;
    gap: 10px;
  }
  .filterDrawerRow select {
    flex: 1;
    min-height: 44px;
    padding: 10px 12px;
    border-radius: var(--radius);
    border: 1px solid var(--border-color);
    background: var(--bg-app);
    font-size: 16px;
    color: var(--text-main);
  }
  .filterDrawerChecks {
    display: flex;
    gap: 16px;
    flex-wrap: wrap;
  }
  #filterDrawerOverlay {
    display: none;
    position: fixed;
    inset: 0;
    z-index: 199;
    background: rgba(0,0,0,0.45);
  }
  #filterDrawerOverlay.open { display: block; }

  .filterActiveDot::after {
    content: '';
    display: inline-block;
    width: 7px; height: 7px;
    background: #1A5C63;
    border-radius: 50%;
    margin-left: 5px;
    vertical-align: middle;
  }
}

@media (min-width: 768px) and (min-height: 501px) {
  .filterDrawer { display: none !important; }
  #filterDrawerOverlay { display: none !important; }
}

/* Phone landscape (e.g. iPhone in landscape): viewport is wider than 767px
   but too short (~393px) for the desktop inline-controls layout. Use the
   same mobile-bar + slide-up drawer pattern as portrait mobile. The
   max-height: 500px threshold sits between phone landscape (~390-430px) and
   tablet landscape (~768px+), so iPad Air is unaffected. */
@media (orientation: landscape) and (max-height: 500px) {
  .hero .heroTitle { display: none; }
  .hero .heroActions { display: none; }
  .hero { padding: 0; min-height: 0; border-bottom: none; }
  .mobileBar {
    display: flex;
    align-items: center;
    position: sticky;
    top: 0;
    z-index: 100;
    background: var(--bg-card);
    border-bottom: 1px solid var(--border-color);
    padding: 0 8px;
    height: 52px;
    gap: 2px;
  }
  .controls { display: none !important; }
  .filterToggleBtn { display: inline-flex !important; align-items: center; gap: 6px; }
  main { padding-top: 0; }
  .filterDrawer {
    position: fixed;
    bottom: 0; left: 0; right: 0;
    z-index: 200;
    background: var(--bg-card);
    border-top: 2px solid #1A5C63;
    border-radius: 14px 14px 0 0;
    transform: translateY(100%);
    transition: transform 0.28s cubic-bezier(0.32, 0.72, 0, 1);
    max-height: 80vh;
    overflow-y: auto;
  }
  .filterDrawer.open { transform: translateY(0); }
  #filterDrawerOverlay {
    display: none;
    position: fixed;
    inset: 0;
    z-index: 199;
    background: rgba(0,0,0,0.45);
  }
  #filterDrawerOverlay.open { display: block; }
}

.status { font-size: 0.9rem; color: var(--text-muted); margin-bottom: 15px; padding: 0 16px; font-weight: 500; }
.toast {
  position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
  background: #1A5C63; color: #f0fdfa; padding: 12px 20px; border-radius: 8px;
  font-size: 0.9rem; font-weight: 500; z-index: 9999;
  box-shadow: 0 4px 12px rgba(0,0,0,0.4);
  transition: opacity 0.3s ease;
  display: flex; flex-direction: column; align-items: center; gap: 10px;
  min-width: 260px; max-width: 90vw; text-align: center;
}
.toastActions { display: flex; gap: 8px; }
.toastActions.hidden { display: none; }
.toastBtn {
  all: unset; cursor: pointer; padding: 6px 14px; border-radius: 6px;
  font-size: 0.85rem; font-weight: 600; border: 1px solid rgba(255,255,255,0.3);
  color: #f0fdfa; background: rgba(255,255,255,0.1);
  transition: background 0.15s;
}
.toastBtn:hover { background: rgba(255,255,255,0.22); }
.toastBtnPrimary { background: rgba(255,255,255,0.25); border-color: rgba(255,255,255,0.5); }
.toastBtnPrimary:hover { background: rgba(255,255,255,0.38); }
.toast.hidden { display: none; }
.hidden { display: none !important; }
CUSTOMCSS


# ===================================================================
# Summary
# ===================================================================
echo
if [ "${DRY_RUN}" = "1" ]; then
  log "Dry run complete. Re-run without --dry-run to write these files."
  exit 0
fi

log "Deployment files written to ${PROJECT_DIR}"
if [ -d "${BACKUP_DIR}" ]; then
  log "Previous versions backed up to: ${BACKUP_DIR}"
fi
echo
log "Deployed known-good build (see header comment for fix/changelog detail)."
echo
log "Next steps:"
echo "    cd ${PROJECT_DIR}"
echo "    docker compose build"
echo "    docker compose up -d"
echo
echo "  If Caddy was already running and only the Caddyfile changed:"
echo "    docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile \\"
echo "      || docker compose restart caddy"
echo
if [ -d "${BACKUP_DIR}" ]; then
  log "To roll back any single file:"
  echo "    cp ${BACKUP_DIR}/<relative-path> ${PROJECT_DIR}/<relative-path>"
fi
