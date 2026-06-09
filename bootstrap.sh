#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="${HOME}/leesfeeds"

echo "Creating project in: ${PROJECT_DIR}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not installed or not in PATH."
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose is not available."
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "ERROR: tailscale is not installed or not in PATH."
  echo "Install/configure Tailscale first, then rerun this script."
  exit 1
fi

TS_HOST_IP="$(tailscale ip -4 | head -n 1)"

if [ -z "${TS_HOST_IP}" ]; then
  echo "ERROR: could not determine Tailscale IPv4 address."
  echo "Check that Tailscale is running and authenticated."
  exit 1
fi

mkdir -p "${PROJECT_DIR}/app/static"
mkdir -p "${PROJECT_DIR}/data"
mkdir -p "${PROJECT_DIR}/scripts"
mkdir -p "${PROJECT_DIR}/caddy/certs"

cd "${PROJECT_DIR}"

cat > .env <<EOF
TS_HOST_IP=${TS_HOST_IP}
EOF

# -----------------------------------------------------------------
# Tailscale hostname detection
# -----------------------------------------------------------------
TS_HOSTNAME="$(tailscale status --json 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
self = d.get('Self', {})
dns = self.get('DNSName', '')
print(dns.rstrip('.'))
" 2>/dev/null || true)"

if [ -z "${TS_HOSTNAME}" ]; then
  echo "WARNING: Could not detect Tailscale hostname automatically."
  echo "You will need to set TS_HOSTNAME manually in caddy/Caddyfile."
  TS_HOSTNAME="YOUR-MACHINE.YOUR-TAILNET.ts.net"
fi

echo "TS_HOSTNAME=${TS_HOSTNAME}" >> .env
echo "Tailscale hostname: ${TS_HOSTNAME}"

# -----------------------------------------------------------------
# Caddyfile
# -----------------------------------------------------------------
cat > caddy/Caddyfile <<CADDYEOF
${TS_HOSTNAME} {
  tls /etc/caddy/certs/cert.pem /etc/caddy/certs/key.pem

  reverse_proxy opml-reader:8080

  encode gzip

  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains"
    X-Content-Type-Options "nosniff"
    X-Frame-Options "DENY"
    Referrer-Policy "strict-origin-when-cross-origin"
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

# -----------------------------------------------------------------
# Cert renewal helper
# -----------------------------------------------------------------
cat > scripts/renew_certs.sh << 'CERTEOF'
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

chmod +x scripts/renew_certs.sh

# -----------------------------------------------------------------
# Fetch initial cert
# -----------------------------------------------------------------
echo
echo "Fetching initial Tailscale TLS cert for ${TS_HOSTNAME}…"
if sudo tailscale cert \
     --cert-file "${PROJECT_DIR}/caddy/certs/cert.pem" \
     --key-file  "${PROJECT_DIR}/caddy/certs/key.pem" \
     "${TS_HOSTNAME}" 2>/dev/null; then
  sudo chmod 644 "${PROJECT_DIR}/caddy/certs/cert.pem"
  sudo chmod 640 "${PROJECT_DIR}/caddy/certs/key.pem"
  echo "Cert fetched successfully."
else
  echo "WARNING: tailscale cert fetch failed."
  echo "Run manually before starting the stack:"
  echo "  sudo tailscale cert --cert-file ${PROJECT_DIR}/caddy/certs/cert.pem \\"
  echo "                       --key-file  ${PROJECT_DIR}/caddy/certs/key.pem \\"
  echo "                      ${TS_HOSTNAME}"
fi

# -----------------------------------------------------------------
# docker-compose.yml
# -----------------------------------------------------------------
cat > docker-compose.yml <<'EOF'
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

# -----------------------------------------------------------------
# Dockerfile
# -----------------------------------------------------------------
cat > Dockerfile <<'EOF'
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

# -----------------------------------------------------------------
# requirements.txt
# -----------------------------------------------------------------
cat > requirements.txt <<'EOF'
fastapi==0.115.6
uvicorn[standard]==0.34.0
feedparser==6.0.11
beautifulsoup4==4.12.3
pydantic==2.10.4
requests==2.32.3
python-multipart==0.0.20
EOF

# -----------------------------------------------------------------
# Generate Initial Pre-seeded OPML Collection
# -----------------------------------------------------------------
cat > scripts/write_clean_opml.py <<'EOF'
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

python3 scripts/write_clean_opml.py

# -----------------------------------------------------------------
# DB pruning script
# -----------------------------------------------------------------
cat > scripts/prune_db.sh << 'PRUNEEOF'
#!/usr/bin/env bash
set -euo pipefail
DB="${PROJECT_DIR}/data/opml_reader.sqlite3"
DAYS=90
sqlite3 "${DB}" "
  DELETE FROM items
  WHERE is_read    = 1
    AND is_starred = 0
    AND published  < datetime('now', '-${DAYS} days');
"
sqlite3 "${DB}" "VACUUM;"
echo "$(date -u +%FT%TZ) pruned items older than ${DAYS} days. DB: $(du -sh ${DB} | cut -f1)"
PRUNEEOF
chmod +x scripts/prune_db.sh

# -----------------------------------------------------------------
# FastAPI backend — app/main.py
# -----------------------------------------------------------------
cat > app/main.py <<'EOF'
import html
import os
import sqlite3
import threading
import time
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor, as_completed
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional, List

import feedparser
from bs4 import BeautifulSoup
from fastapi import FastAPI, HTTPException, Query, UploadFile, File
from fastapi.responses import FileResponse, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

APP_TITLE            = os.getenv("APP_TITLE",            "Lee's Feeds")
DATABASE_PATH        = os.getenv("DATABASE_PATH",        "/data/opml_reader.sqlite3")
SEED_OPML_PATH       = os.getenv("SEED_OPML_PATH",       "/data/seed.opml")
FEED_REFRESH_MINUTES = int(os.getenv("FEED_REFRESH_MINUTES", "30"))
MAX_ITEMS_PER_FEED   = int(os.getenv("MAX_ITEMS_PER_FEED",   "100"))
REFRESH_WORKERS      = int(os.getenv("REFRESH_WORKERS",      "8"))

BASE_DIR   = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

SECURITY_KEYWORDS = [
    "cve", "ransomware", "breach", "zero-day", "zeroday", "exploit",
    "malware", "phishing", "vulnerability", "patch", "advisory",
    "microsoft", "defender", "entra", "identity", "cloud", "attack",
    "threat", "incident", "backdoor", "botnet", "supply chain",
]

@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    seed_default_profile()
    threading.Thread(target=refresh_all_feeds, daemon=True).start()
    threading.Thread(target=refresh_loop,      daemon=True).start()
    yield

app = FastAPI(title=APP_TITLE, lifespan=lifespan)
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

# -----------------------------------------------------------------
# Models
# -----------------------------------------------------------------
class ItemState(BaseModel):
    is_read:    Optional[bool] = None
    is_starred: Optional[bool] = None

class FeedEdit(BaseModel):
    title: str
    category: str
    xml_url: str
    html_url: Optional[str] = ""

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

# -----------------------------------------------------------------
# DB helpers
# -----------------------------------------------------------------
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

# -----------------------------------------------------------------
# Schema & Data Initialization
# -----------------------------------------------------------------
def init_db():
    Path(DATABASE_PATH).parent.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS profiles (
                id   INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE
            );
            CREATE TABLE IF NOT EXISTS feeds (
                id           INTEGER PRIMARY KEY AUTOINCREMENT,
                profile_id   INTEGER NOT NULL DEFAULT 1,
                title        TEXT NOT NULL,
                category     TEXT NOT NULL,
                xml_url      TEXT NOT NULL,
                html_url     TEXT,
                last_checked TEXT,
                last_error   TEXT,
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
            CREATE INDEX IF NOT EXISTS idx_feeds_category  ON feeds(category);
            CREATE INDEX IF NOT EXISTS idx_feeds_profile   ON feeds(profile_id);
        """)
        conn.execute("INSERT OR IGNORE INTO profiles (id, name) VALUES (1, 'Default')")

def seed_default_profile():
    with db() as conn:
        count = conn.execute("SELECT COUNT(*) as c FROM feeds WHERE profile_id = 1").fetchone()["c"]
        if count > 0: return

    seed_file = Path(SEED_OPML_PATH)
    if not seed_file.exists(): return

    try:
        tree = ET.parse(seed_file)
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
        with db() as conn:
            for f in feeds:
                conn.execute("""
                    INSERT OR IGNORE INTO feeds (profile_id, title, category, xml_url, html_url)
                    VALUES (1, ?, ?, ?, ?)
                """, (f["title"], f["category"], f["xml_url"], f["html_url"]))
    except Exception as e:
        print(f"Error seeding default profile: {e}")

# -----------------------------------------------------------------
# Parser Mechanics
# -----------------------------------------------------------------
def normalise_published(entry) -> str:
    parsed = getattr(entry, "published_parsed", None) or getattr(entry, "updated_parsed", None)
    if parsed:
        return datetime(*parsed[:6], tzinfo=timezone.utc).isoformat()
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
    except Exception: pass
    return None

def refresh_one_feed(feed) -> int:
    parsed = feedparser.parse(feed["xml_url"])
    now    = utc_now()
    error  = None
    count  = 0

    if parsed.bozo and getattr(parsed, "bozo_exception", None):
        error = str(parsed.bozo_exception)[:500]

    with db() as conn:
        for entry in parsed.entries[:MAX_ITEMS_PER_FEED]:
            title     = clean_text(getattr(entry, "title", "Untitled story"), 300)
            link      = getattr(entry, "link", "") or feed["html_url"] or ""
            teaser    = clean_text(entry_summary(entry), 420)
            author    = clean_text(getattr(entry, "author", ""), 120)
            published = normalise_published(entry)
            image_url = extract_image(entry, link)

            guid = getattr(entry, "id", None) or getattr(entry, "guid", None) or link or f'{feed["xml_url"]}:{title}:{published}'

            try:
                conn.execute("""
                    INSERT INTO items (feed_id, guid, title, link, teaser, author, published, fetched_at, image_url)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (feed["id"], guid, title, link, teaser, author, published, now, image_url))
                count += 1
            except sqlite3.IntegrityError:
                pass

        conn.execute("UPDATE feeds SET last_checked = ?, last_error = ? WHERE id = ?", (now, error, feed["id"]))
    return count

def refresh_all_feeds():
    with db() as conn:
        feeds = conn.execute("SELECT * FROM feeds ORDER BY category, title").fetchall()
    with ThreadPoolExecutor(max_workers=REFRESH_WORKERS) as executor:
        futures = {executor.submit(refresh_one_feed, feed): feed for feed in feeds}
        for future in as_completed(futures):
            feed = futures[future]
            try:
                future.result()
            except Exception as exc:
                with db() as conn:
                    conn.execute("UPDATE feeds SET last_checked = ?, last_error = ? WHERE id = ?", (utc_now(), str(exc)[:500], feed["id"]))

def refresh_loop():
    while True:
        time.sleep(max(FEED_REFRESH_MINUTES, 5) * 60)
        refresh_all_feeds()

# -----------------------------------------------------------------
# API Routes
# -----------------------------------------------------------------
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
        with db() as conn:
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
    try:
        with db() as conn:
            cur = conn.execute("""
                INSERT INTO feeds (profile_id, title, category, xml_url, html_url)
                VALUES (?, ?, ?, ?, ?)
            """, (profile_id, f.title, f.category, f.xml_url, f.html_url))
            return {"id": cur.lastrowid}
    except sqlite3.IntegrityError:
        raise HTTPException(400, "Feed tracking conflict.")

@app.put("/api/feeds/{feed_id}")
def edit_feed(feed_id: int, f: FeedEdit):
    with db() as conn:
        cur = conn.execute("""
            UPDATE feeds SET title = ?, category = ?, xml_url = ?, html_url = ?
            WHERE id = ?
        """, (f.title, f.category, f.xml_url, f.html_url, feed_id))
        if cur.rowcount == 0: raise HTTPException(404, "Feed stream not found.")
    return {"status": "updated"}

@app.delete("/api/feeds/{feed_id}")
def delete_feed(feed_id: int):
    with db() as conn:
        conn.execute("DELETE FROM feeds WHERE id = ?", (feed_id,))
    return {"status": "deleted"}

@app.get("/api/health")
def health(profile_id: int = 1):
    with db() as conn:
        rows = conn.execute("""
            SELECT f.id, f.title, f.category, f.xml_url, f.html_url, f.last_checked, f.last_error,
                   COUNT(i.id) AS item_count, SUM(CASE WHEN i.is_read = 0 THEN 1 ELSE 0 END) AS unread_count,
                   MAX(i.fetched_at) AS last_item_fetched_at
            FROM feeds f
            LEFT JOIN items i ON i.feed_id = f.id
            WHERE f.profile_id = ?
            GROUP BY f.id
            ORDER BY CASE WHEN f.last_error IS NOT NULL AND f.last_error != '' THEN 0 WHEN f.last_checked IS NULL THEN 1 ELSE 2 END, f.category, f.title
        """, (profile_id,)).fetchall()
    output = []
    for row in rows:
        d = dict(row)
        d["status"] = "error" if d["last_error"] else ("never_checked" if not d["last_checked"] else "healthy")
        output.append(d)
    return output

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
    with db() as conn:
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
    with db() as conn:
        cur = conn.execute(sql, params)
        return {"updated": cur.rowcount, "read_at": now}

@app.post("/api/refresh")
def refresh():
    threading.Thread(target=refresh_all_feeds, daemon=True).start()
    return {"status": "started", "refreshed_at": utc_now()}

# -----------------------------------------------------------------
# OPML Export
# -----------------------------------------------------------------
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
    filename = f"feeds_{profile['name'].lower().replace(' ', '_')}.opml"
    return Response(content=xml_data, media_type="application/xml",
                    headers={"Content-Disposition": f'attachment; filename="{filename}"'})

# -----------------------------------------------------------------
# OPML Import
# -----------------------------------------------------------------
@app.post("/api/profiles/{profile_id}/import")
async def import_profile_opml(profile_id: int, file: UploadFile = File(...)):
    with db() as conn:
        profile = conn.execute("SELECT id FROM profiles WHERE id = ?", (profile_id,)).fetchone()
        if not profile:
            raise HTTPException(status_code=404, detail="Target profile does not exist.")
    try:
        content = await file.read()
        root = ET.fromstring(content)
        body = root.find("body")
        if body is None:
            raise HTTPException(status_code=400, detail="Invalid OPML: missing body.")

        imported_feeds = []
        def walk_nodes(node, category="Uncategorised"):
            for child in list(node):
                xml_url = child.attrib.get("xmlUrl")
                title = child.attrib.get("title") or child.attrib.get("text") or "Untitled"
                html_url = child.attrib.get("htmlUrl") or ""
                if xml_url:
                    imported_feeds.append({
                        "title": clean_text(title),
                        "category": clean_text(category) or "Uncategorised",
                        "xml_url": xml_url, "html_url": html_url
                    })
                else:
                    next_cat = child.attrib.get("title") or child.attrib.get("text") or category
                    walk_nodes(child, next_cat)

        walk_nodes(body)
        inserted_count = 0
        with db() as conn:
            for f in imported_feeds:
                cur = conn.execute("""
                    INSERT OR IGNORE INTO feeds (profile_id, title, category, xml_url, html_url)
                    VALUES (?, ?, ?, ?, ?)
                """, (profile_id, f["title"], f["category"], f["xml_url"], f["html_url"]))
                if cur.rowcount > 0:
                    inserted_count += 1

        threading.Thread(target=refresh_all_feeds, daemon=True).start()
        return {"status": "success", "total_found": len(imported_feeds), "newly_added": inserted_count}
    except ET.ParseError:
        raise HTTPException(status_code=400, detail="Failed to parse OPML XML.")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Import error: {str(e)}")
EOF

# -----------------------------------------------------------------
# Frontend UI — app/static/index.html
# -----------------------------------------------------------------
cat > app/static/index.html <<'FRONTENDHTML'
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
      <button id="themeToggleBtn" class="secondary themeToggleBtn" aria-label="Toggle light/dark mode" title="Toggle light/dark mode">☀️</button>
      <button id="healthBtn" class="secondary">Feed health</button>
      <button id="manageFeedsBtn" class="secondary">Manage feeds</button>
      <button id="markReadBtn" class="secondary">Mark read</button>
      <button id="refreshBtn">Refresh now</button>
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
    <div id="toast" class="toast hidden"></div>
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
      loadingMore: false
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
        <span style="font-style:italic; color:#94a3b8;">${filterLabel}</span>
      `;
      const mob = el("statsMobile");
      if (mob) mob.textContent = `✉️ ${m.unread_count}${m.error_count ? `  ⚠️${m.error_count}` : ""}`;
    }

    function updateStatusLabel() {
      const statusEl = el("status");
      if (!statusEl) return;
      if (!state.items.length) {
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
      try {
        state.items = await api(`/api/items?${p}`);
        if (state.items.length < state.limit) {
          state.hasMore = false;
        }
      } catch(e) { console.error(e); }
      el("grid").classList.remove("loading");
      el("grid").innerHTML = "";
      renderItems(state.items);
      updateStatusLabel();
      loadMeta();
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
          renderItems(nextChunk);
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
      return `hsl(${hue}, 28%, 22%)`;
    }

    function renderItems(chunk) {
      const grid = el("grid");
      chunk.forEach(item => {
        const card = document.createElement("article");
        card.className = `card ${item.is_read ? 'read' : 'unread'}`;
        let imgHtml = "";
        if (item.image_url) {
          imgHtml = `<div class="cardImage"><img src="${esc(item.image_url)}" alt="" loading="lazy" onerror="this.closest('.cardImage').replaceWith(Object.assign(document.createElement('div'), {className:'cardImagePlaceholder', style:'background:${feedPlaceholderColour(item.feed_title)}', innerHTML:'<span>${feedInitial(item.feed_title)}</span>'}))"/></div>`;
        } else {
          imgHtml = `<div class="cardImagePlaceholder" style="background:${feedPlaceholderColour(item.feed_title)}"><span>${feedInitial(item.feed_title)}</span></div>`;
        }
        card.innerHTML = `
          ${imgHtml}
          <div class="cardBody">
            <div class="cardMeta">
              <span class="categoryTag">${esc(item.category)}</span>
              <span class="feedTitleTag">${esc(item.feed_title)}</span>
              ${item.author ? `<span class="authorTag">by ${esc(item.author)}</span>` : ''}
              <span class="dateTag">${fmtDate(item.published)}</span>
            </div>
            <h2 class="cardTitle"><a href="${esc(item.link)}" target="_blank" rel="noopener">${esc(item.title)}</a></h2>
            <p class="cardTeaser">${esc(item.teaser)}</p>
            <div class="cardSummaryActions">
              <span class="iconAction starBtn" title="Toggle Star">${item.is_starred ? '★' : '☆'}</span>
              <span class="iconAction readToggleBtn" title="Toggle Read State">${item.is_read ? '🗙' : '✔'}</span>
            </div>
          </div>
        `;

        card.querySelector(".readToggleBtn").addEventListener("click", (e) => { e.stopPropagation(); toggleRead(item, card); });
        card.querySelector(".starBtn").addEventListener("click", (e) => { e.stopPropagation(); toggleStar(item, card); });
        card.querySelector(".cardTitle a").addEventListener("click", (e) => {
          if (!item.is_read) markReadInstant(item, card);
        });
        grid.appendChild(card);
      });
    }

    function markReadInstant(item, card) {
      item.is_read = true;
      if (state.unreadOnly) {
        card.remove();
        state.items = state.items.filter(i => i.id !== item.id);
        updateStatusLabel();
      } else {
        card.className = "card read";
        const btn = card.querySelector(".readToggleBtn");
        if (btn) btn.textContent = '🗙';
      }
      api(`/api/items/${item.id}`, { method: "PATCH", body: JSON.stringify({ is_read: true }) })
        .then(() => loadMeta())
        .catch(e => console.error(e));
    }

    async function toggleRead(item, card) {
      const nextState = !item.is_read;
      // Optimistic update
      item.is_read = nextState;
      if (state.unreadOnly && nextState) {
        card.remove();
        state.items = state.items.filter(i => i.id !== item.id);
        updateStatusLabel();
      } else {
        card.className = `card ${nextState ? 'read' : 'unread'}`;
        card.querySelector(".readToggleBtn").textContent = nextState ? '🗙' : '✔';
      }
      try {
        await api(`/api/items/${item.id}`, { method: "PATCH", body: JSON.stringify({ is_read: nextState }) });
        loadMeta();
      } catch (e) { console.error(e); }
    }

    async function toggleStar(item, card) {
      const nextState = !item.is_starred;
      try {
        const updated = await api(`/api/items/${item.id}`, {
          method: "PATCH",
          body: JSON.stringify({ is_starred: nextState })
        });
        item.is_starred = updated.is_starred;
        const btn = card.querySelector(".starBtn");
        btn.textContent = item.is_starred ? '★' : '☆';
        await loadMeta();
      } catch (e) { console.error(e); }
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
        panel.innerHTML = `
          <h2 style="margin-bottom:16px; color:#f8fafc;">Feed Synchronization Diagnostics</h2>
          <table class="healthTable">
            <thead>
              <tr>
                <th>Stream Label</th>
                <th>Category</th>
                <th>Status</th>
                <th>Count</th>
                <th>Latest Capture</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              ${state.health.map(f => `
                <tr class="status-${f.status}">
                  <td>
                    <strong>${esc(f.title)}</strong><br/>
                    <small style="color:#94a3b8;">${esc(f.xml_url)}</small>
                    ${f.last_error ? `<div class="errorText">${esc(f.last_error)}</div>` : ''}
                  </td>
                  <td>${esc(f.category)}</td>
                  <td><span class="badge badge-${f.status}">${f.status}</span></td>
                  <td>${f.unread_count} / ${f.item_count}</td>
                  <td>${fmtDate(f.last_item_fetched_at) || 'Never'}</td>
                  <td>
                    <button class="smallEditFeedBtn" data-id="${f.id}">Edit</button>
                    <button class="smallDeleteFeedBtn danger" data-id="${f.id}">Delete</button>
                  </td>
                </tr>
              `).join('')}
            </tbody>
          </table>
        `;

        panel.querySelectorAll(".smallEditFeedBtn").forEach(b => {
          b.addEventListener("click", () => openEditFeedModal(Number(b.dataset.id)));
        });
        panel.querySelectorAll(".smallDeleteFeedBtn").forEach(b => {
          b.addEventListener("click", () => deleteFeed(Number(b.dataset.id)));
        });

      } catch(e) { panel.innerHTML = "Failed diagnostics fetch."; }
    }

    function openEditFeedModal(id) {
      const f = state.health.find(x => x.id === id);
      if (!f) return;
      el("modalTitle").textContent = "Edit Feed Settings";
      el("modalBody").innerHTML = `
        <div class="form-field" style="margin-bottom:12px;">
          <label style="display:block; margin-bottom:4px; color:#cbd5e1;">Feed Name</label>
          <input type="text" id="editFeedTitle" value="${esc(f.title)}" />
        </div>
        <div class="form-field" style="margin-bottom:12px;">
          <label style="display:block; margin-bottom:4px; color:#cbd5e1;">Category Assignment</label>
          <input type="text" id="editFeedCategory" value="${esc(f.category)}" />
        </div>
        <div class="form-field" style="margin-bottom:12px;">
          <label style="display:block; margin-bottom:4px; color:#cbd5e1;">XML Endpoint Address</label>
          <input type="url" id="editFeedXmlUrl" value="${esc(f.xml_url)}" />
        </div>
        <div class="form-field">
          <label style="display:block; margin-bottom:4px; color:#cbd5e1;">Homepage Web Address</label>
          <input type="url" id="editFeedHtmlUrl" value="${esc(f.html_url)}" />
        </div>
      `;

      const saveBtn = el("modalSaveBtn");
      const clone = saveBtn.cloneNode(true);
      saveBtn.parentNode.replaceChild(clone, saveBtn);

      clone.addEventListener("click", async () => {
        const payload = {
          title: el("editFeedTitle").value.trim(),
          category: el("editFeedCategory").value.trim(),
          xml_url: el("editFeedXmlUrl").value.trim(),
          html_url: el("editFeedHtmlUrl").value.trim()
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
          <h2 style="margin-bottom:20px; color:#f8fafc;">Feed Management Control</h2>
          
          <div style="padding-bottom:20px; margin-bottom:20px; border-bottom:1px dashed #334155;">
            <h3 style="margin-bottom:12px; font-size:1.1rem; color:#cbd5e1;">Switch / Generate Dynamic Profile</h3>
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
            <h3 style="margin-bottom:12px; font-size:1.1rem; color:#cbd5e1;">Register New Subscription Target</h3>
            <div style="display:grid; grid-template-columns:1fr; gap:12px; margin-bottom:16px;">
              <input type="text" id="addFeedTitle" placeholder="Custom feed shorthand title (e.g. Wired Security)" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
              <input type="text" id="addFeedCategory" placeholder="Target Category box grouping (e.g. Security)" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
              <input type="url" id="addFeedXmlUrl" placeholder="Direct link RSS/Atom XML endpoint" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
              <input type="url" id="addFeedHtmlUrl" placeholder="Optional standard website homepage URL" style="background:var(--bg-app); color:var(--text-main); border:1px solid var(--border-color); padding:8px; border-radius:6px;" />
            </div>
            <button id="submitNewFeedBtn" style="width:100%; padding:10px;">Register Stream Instance</button>
          </div>

          <div style="padding-top:20px; margin-top:4px; border-top:1px dashed #334155;">
            <h3 style="margin-bottom:12px; font-size:1.1rem; color:#cbd5e1;">OPML Import / Export</h3>
            <div style="display:flex; align-items:center; flex-wrap:wrap; gap:12px; background:var(--bg-app); padding:14px; border-radius:6px; border:1px solid var(--border-color);">
              <div style="display:flex; flex-direction:column; gap:4px;">
                <span style="font-size:0.8rem; font-weight:bold; color:#94a3b8;">Import OPML file:</span>
                <input type="file" id="opmlFileInput" accept=".opml,.xml" style="font-size:0.85rem; min-height:auto; padding:4px; background:transparent; border:none; color:#94a3b8;" />
              </div>
              <button id="importOpmlBtn" class="secondary" style="padding:8px 14px;">Upload &amp; Merge</button>
              <div style="margin-left:auto; display:flex; flex-direction:column; gap:4px; align-items:flex-end;">
                <span style="font-size:0.8rem; font-weight:bold; color:#94a3b8;">Backup feeds:</span>
                <button id="exportOpmlBtn" class="secondary" style="padding:8px 14px;">Download OPML</button>
              </div>
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
        const payload = {
          title: el("addFeedTitle").value.trim(),
          category: el("addFeedCategory").value.trim(),
          xml_url: el("addFeedXmlUrl").value.trim(),
          html_url: el("addFeedHtmlUrl").value.trim()
        };
        if (!payload.title || !payload.category || !payload.xml_url) return alert("Fill core subscription parameters.");
        try {
          await api(`/api/feeds?profile_id=${state.currentProfileId}`, { method: "POST", body: JSON.stringify(payload) });
          alert("Feed registered!");
          el("addFeedTitle").value = "";
          el("addFeedCategory").value = "";
          el("addFeedXmlUrl").value = "";
          el("addFeedHtmlUrl").value = "";
          await loadMeta();
          await loadFeeds();
        } catch(e) { alert(e); }
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
    });

    el("feed").addEventListener("change", e => {
      state.feedId = e.target.value;
      loadItems();
    });

    let searchTimeout;
    el("search").addEventListener("input", e => {
      clearTimeout(searchTimeout);
      searchTimeout = setTimeout(() => {
        state.q = e.target.value.trim();
        loadItems();
      }, 250);
    });

    el("unreadOnly").addEventListener("change", e => { state.unreadOnly = e.target.checked; loadItems(); });
    el("starredOnly").addEventListener("change", e => { state.starredOnly = e.target.checked; loadItems(); });

    el("healthBtn").addEventListener("click", showHealth);

    (function initTheme() {
      const btn = el("themeToggleBtn");
      const apply = (theme) => {
        if (theme === "light") {
          document.documentElement.setAttribute("data-theme", "light");
          btn.textContent = "🌙";
          btn.title = "Switch to dark mode";
        } else {
          document.documentElement.removeAttribute("data-theme");
          btn.textContent = "☀️";
          btn.title = "Switch to light mode";
        }
      };
      apply(localStorage.getItem("lf-theme") || "dark");
      const toggle = () => {
        const next = document.documentElement.getAttribute("data-theme") === "light" ? "dark" : "light";
        localStorage.setItem("lf-theme", next);
        apply(next);
      };
      btn.addEventListener("click", toggle);
      el("themeToggleBtnMobile").addEventListener("click", toggle);
    })();

    // Mobile bar wiring
    el("homeBtnMobile").addEventListener("click", () => {
      state.category = ""; state.feedId = ""; state.q = ""; state.securityDigest = false;
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
      const p = new URLSearchParams();
      p.set("profile_id", state.currentProfileId);
      if (state.category) p.set("category", state.category);
      if (state.feedId) p.set("feed_id", state.feedId);
      try {
        await api(`/api/items/mark-all-read?${p}`, { method: "POST" });
        initApplicationContext();
      } catch(e) { console.error(e); }
    });

    function showToast(msg, durationMs = 3000) {
      const t = el("toast");
      t.textContent = msg;
      t.classList.remove("hidden");
      clearTimeout(showToast._timer);
      showToast._timer = setTimeout(() => t.classList.add("hidden"), durationMs);
    }

    el("refreshBtn").addEventListener("click", async () => {
      const btn = el("refreshBtn");
      if (btn.disabled) return;
      btn.disabled = true;
      try {
        await api("/api/refresh", { method: "POST" });
        const total = 15;
        let remaining = total;
        showToast(`Refreshing feeds… reloading in ${remaining}s`, (total + 1) * 1000);
        const tick = setInterval(() => {
          remaining--;
          if (remaining <= 0) {
            clearInterval(tick);
            btn.disabled = false;
            el("toast").classList.add("hidden");
            if (state.mode === "stories") initApplicationContext();
          } else {
            showToast(`Refreshing feeds… reloading in ${remaining}s`, (remaining + 1) * 1000);
          }
        }, 1000);
      } catch(e) {
        showToast("Refresh failed.", 3000);
        btn.disabled = false;
      }
    });

    el("profileSelect").addEventListener("change", e => {
      state.currentProfileId = Number(e.target.value);
      state.category = ""; state.feedId = "";
      initApplicationContext();
    });

    // ----- Filter Drawer (phone) -----
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
      if ((window.innerHeight + window.scrollY) >= document.documentElement.scrollHeight - 150) {
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

# -----------------------------------------------------------------
# CSS Clean Dark Framework Overhaul — app/static/styles.css
# -----------------------------------------------------------------
cat > app/static/styles.css <<'CUSTOMCSS'
:root {
  --primary: #1A5C63;
  --primary-hover: #14474d;
  --bg-app: #0f172a;
  --bg-card: #1e293b;
  --border-color: #334155;
  --text-main: #f8fafc;
  --text-muted: #94a3b8;
  --radius: 8px;
  --theme-toggle-icon: "☀️";
  color-scheme: dark;
}

[data-theme="light"] {
  --bg-app: #f1f5f9;
  --bg-card: #ffffff;
  --border-color: #e2e8f0;
  --text-main: #0f172a;
  --text-muted: #64748b;
  --theme-toggle-icon: "🌙";
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

/* Responsive Grid/Flex Headers */
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

/* Controls Framework */
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

/* ── Mobile sticky bar ───────────────────────────── */
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

  /* sun shown in dark mode (click → light), moon shown in light mode (click → dark) */
  .iconMoon { display: none; }
  .iconSun  { display: block; }
  [data-theme="light"] .iconMoon { display: block; }
  [data-theme="light"] .iconSun  { display: none; }

  main { padding-top: 0; }
}
/* ── End mobile bar ──────────────────────────────── */

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
button.secondary:hover { background: #334155; }

.toggle {
  display: inline-flex;
  align-items: center;
  gap: 8px;
  min-height: 44px;
  cursor: pointer;
  font-size: 14px;
}
.toggle input { width: 18px; height: 18px; }

/* Dynamic Multi-Column Distribution */
.grid {
  display: grid;
  grid-template-columns: 1fr;
  grid-auto-rows: 1fr;
  gap: 16px;
  padding: 16px;
  align-items: stretch;
}

@media (min-width: 640px) { .grid { grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); } }

/* Unified Premium Card Design */
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
  color: rgba(255,255,255,0.18);
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
.categoryTag { background: #1e3a8a; color: #93c5fd; padding: 2px 6px; border-radius: 4px; font-weight: 600; }
.feedTitleTag { color: #f1f5f9; font-weight: 600; }

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

/* Summary Action Icons Integration */
.cardSummaryActions {
  display: flex;
  gap: 16px;
  margin-top: auto;
  padding-top: 10px;
  border-top: 1px solid #334155;
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

/* Diagnostics System Sheet overrides */
.healthPanel { padding: 16px; background: var(--bg-card); margin: 16px; border-radius: var(--radius); border: 1px solid var(--border-color); overflow-x: auto; }
.healthTable { width: 100%; border-collapse: collapse; font-size: 0.9rem; color: #f8fafc; }
.healthTable th, .healthTable td { padding: 12px; border-bottom: 1px solid #334155; }
.healthTable th { background: var(--bg-app); }
.errorText { color: #ef4444; font-size: 0.8rem; margin-top: 4px; font-family: monospace; }
.badge { display: inline-block; padding: 2px 6px; font-size: 0.7rem; font-weight: 600; border-radius: 4px; }
.badge-error { background: #7f1d1d; color: #fca5a5; }
.badge-healthy { background: #14532d; color: #86efac; }



/* Modals Definition Framework */
.modal { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0, 0, 0, 0.7); display: flex; align-items: center; justify-content: center; z-index: 2000; padding: 16px; }
.modal-content { background: var(--bg-card); padding: 24px; border-radius: var(--radius); width: 100%; max-width: 500px; border: 1px solid var(--border-color); }
.modal input { width: 100%; background: var(--bg-app); color: var(--text-main); border: 1px solid var(--border-color); padding: 10px; border-radius: 6px; margin-top: 4px; }
/* Drawer: phone only (single-column breakpoint) */
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
    background: #475569;
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

@media (min-width: 768px) {
  .filterDrawer { display: none !important; }
  #filterDrawerOverlay { display: none !important; }
}

.status { font-size: 0.9rem; color: var(--text-muted); margin-bottom: 15px; padding: 0 16px; font-weight: 500; }
.toast {
  position: fixed; bottom: 24px; left: 50%; transform: translateX(-50%);
  background: #1A5C63; color: #f0fdfa; padding: 10px 20px; border-radius: 6px;
  font-size: 0.9rem; font-weight: 500; z-index: 9999; white-space: nowrap;
  box-shadow: 0 4px 12px rgba(0,0,0,0.4);
  transition: opacity 0.3s ease;
}
.toast.hidden { display: none; }
.hidden { display: none !important; }
CUSTOMCSS

# -----------------------------------------------------------------
# Deployment Execution Framework
# -----------------------------------------------------------------
echo "Deployment structure compiled successfully."
