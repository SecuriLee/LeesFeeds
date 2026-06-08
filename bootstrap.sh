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
  echo "                      --key-file  ${PROJECT_DIR}/caddy/certs/key.pem \\"
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
    count  = 1

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
        raise HTTPException(400, "Profile variant designation name already occupied.")

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

@app.put("/api/items/{item_id}")
def edit_entry(item_id: int, e: EntryEdit):
    with db() as conn:
        cur = conn.execute("UPDATE items SET title = ?, teaser = ? WHERE id = ?", (e.title, e.teaser, item_id))
        if cur.rowcount == 0: raise HTTPException(404, "Item story reference target unavailable.")
    return {"status": "updated"}

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
        like = f"%{q}%"; params.extend([like, like, like])
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
        if cur.rowcount == 0: raise HTTPException(404, "Target story item not found.")
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
# OPML Export Endpoint
# -----------------------------------------------------------------
@app.get("/api/profiles/{profile_id}/export", response_class=Response)
def export_profile_opml(profile_id: int):
    with db() as conn:
        profile = conn.execute("SELECT name FROM profiles WHERE id = ?", (profile_id,)).fetchone()
        if not profile:
            raise HTTPException(status_code=404, detail="Profile configuration not found.")
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
            "text": f["title"],
            "title": f["title"],
            "type": "rss",
            "version": "RSS",
            "htmlUrl": f["html_url"] or "",
            "xmlUrl": f["xml_url"]
        })

    tree = ET.ElementTree(opml)
    ET.indent(tree, space="  ")
    xml_data = ET.tostring(opml, encoding="utf-8", xml_declaration=True)

    filename = f"feeds_{profile['name'].lower().replace(' ', '_')}.opml"
    return Response(
        content=xml_data,
        media_type="application/xml",
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"'
        }
    )

# -----------------------------------------------------------------
# OPML Import Endpoint
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
            raise HTTPException(status_code=400, detail="Invalid OPML structure: missing body block.")

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
                        "xml_url": xml_url,
                        "html_url": html_url
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
        return {
            "status": "success",
            "total_found": len(imported_feeds),
            "newly_added": inserted_count
        }
    except ET.ParseError:
        raise HTTPException(status_code=400, detail="Failed to parse file. Ensure it is a valid OPML XML file.")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal import error: {str(e)}")
EOF

# -----------------------------------------------------------------
# Frontend UI — app/static/index.html
# -----------------------------------------------------------------
cat > app/static/index.html <<'FRONTENDHTML'
<!doctype html>
<html lang="en-GB">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Lee's Feeds</title>
  <link rel="stylesheet" href="/static/styles.css" />
</head>
<body>
  <header class="hero">
    <div class="heroTitle">
      <h1 id="homeBtn" role="button" tabindex="0" title="Back to all stories">Lee's Feeds</h1>
      <p id="stats" class="muted" style="cursor: pointer; display: flex; gap: 14px; align-items: center;" title="Click to view error log feeds"></p>
    </div>
    <div class="heroActions">
      <button id="digestBtn" class="secondary">Security digest</button>
      <button id="healthBtn" class="secondary">Feed health</button>
      <button id="manageFeedsBtn" class="secondary">Manage feeds</button>
      <button id="markReadBtn" class="secondary">Mark shown read</button>
      <button id="refreshBtn">Refresh now</button>
    </div>
  </header>

  <main>
    <section class="controls">
      <div class="profile-select-wrapper" style="display: flex; align-items: center;">
        <select id="profileSelect" style="padding: 6px 10px; min-width: 120px;"></select>
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
    </section>

    <p id="status" class="status"></p>
    
    <section id="grid" class="grid"></section>
    
    <section id="healthPanel" class="healthPanel hidden"></section>

    <div id="editModal" class="modal hidden">
      <div class="modal-content">
        <h3 id="modalTitle" style="margin-bottom: 15px; font-weight: 800;">Edit Properties</h3>
        <div id="modalBody"></div>
        <div class="modal-actions" style="display: flex; justify-content: flex-end; gap: 10px; margin-top: 20px;">
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
      securityDigest: false,
      
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
      });
      sel.value = cur || state.category;
    }

    function updateStats() {
      if (!state.meta) return;
      const m = state.meta;
      const filterLabel = state.securityDigest ? " · security digest" : state.category ? ` · ${state.category}` : "";
      
      el("stats").innerHTML = `
        <span title="${m.feed_count} tracking channels">📡 ${m.feed_count}</span>
        <span title="${m.item_count} cached posts">📖 ${m.item_count}</span>
        <span title="${m.unread_count} unread links">✉️ ${m.unread_count}</span>
        <span title="${m.starred_count} bookmarks">⭐ ${m.starred_count}</span>
        ${m.error_count ? `<span title="${m.error_count} connection errors" style="color: var(--danger); font-weight: bold;">⚠️ ${m.error_count}</span>` : ""}
        <span class="filter-lbl" style="font-style: italic; margin-left: 4px; color: var(--accent); font-weight: 500;">${filterLabel}</span>
      `;
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
      window.scrollTo(0, 0);

      const p = new URLSearchParams();
      p.set("profile_id", state.currentProfileId);
      if (state.category) p.set("category", state.category);
      if (state.feedId) p.set("feed_id", state.feedId);
      if (state.q) p.set("q", state.q);
      if (state.unreadOnly) p.set("unread", "true");
      if (state.starredOnly) p.set("starred", "true");
      if (state.securityDigest) p.set("security_digest", "true");
      p.set("limit", state.limit.toString());
      p.set("offset", state.offset.toString());

      el("status").textContent = "Loading…";
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
      if (state.securityDigest) p.set("security_digest", "true");
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
      updateStatusLabel();
    }

    function updateStatusLabel() {
      if (!state.items.length) {
        el("status").textContent = state.unreadOnly ?
          "All caught up — no unread stories." : "No stories matched your filters.";
      } else {
        el("status").textContent = ""; 
      }
    }

    function renderItems(chunk) {
      const grid = el("grid");
      chunk.forEach(item => {
        const card = document.createElement("article");
        card.className = `card ${item.is_read ? 'read' : 'unread'}`;
        card.style.cursor = "pointer";
        
        let imgHtml = "";
        if (item.image_url) {
          imgHtml = `<div class="cardImage"><img src="${esc(item.image_url)}" alt="" loading="lazy" /></div>`;
        }

        card.innerHTML = `
          ${imgHtml}
          <div class="cardBody">
            <div class="cardMeta">
              <span class="categoryTag">${esc(item.category)}</span>
              <span class="feedTitleTag">${esc(item.feed_title)}</span>
              ${item.author ? `<span class="authorTag">by ${esc(item.author)}</span>` : ''}
            </div>
            <h2 class="cardTitle"><a class="story-anchor" href="${esc(item.link)}" target="_blank" rel="noopener">${esc(item.title)}</a></h2>
            <p class="cardTeaser">${esc(item.teaser)}</p>
            <div class="cardTime">${fmtDate(item.published)}</div>
            <div class="cardActions">
              <button class="btnRead secondary">${item.is_read ? 'Mark unread' : 'Mark read'}</button>
              <button class="btnStar secondary">${item.is_starred ? '★ Starred' : '☆ Star'}</button>
            </div>
          </div>
        `;

        card.addEventListener("click", async (e) => {
          if (e.target.closest(".cardActions")) return;

          if (!item.is_read) {
            const res = await api(`/api/items/${item.id}`, { method: "PATCH", body: JSON.stringify({ is_read: true }) });
            item.is_read = res.is_read;
            
            if (state.unreadOnly) {
              card.remove();
              state.items = state.items.filter(i => i.id !== item.id);
              updateStatusLabel();
            } else {
              card.className = "card read";
              card.querySelector(".btnRead").textContent = "Mark unread";
            }
            loadMeta();
            loadFeeds();
          }

          if (!e.target.classList.contains("story-anchor")) {
            window.open(item.link, "_blank", "noopener,noreferrer");
          }
        });

        card.querySelector(".btnRead").onclick = async (e) => {
          e.stopPropagation();
          const res = await api(`/api/items/${item.id}`, { method: "PATCH", body: JSON.stringify({ is_read: !item.is_read }) });
          item.is_read = res.is_read;
          
          if (state.unreadOnly && item.is_read) {
            card.remove();
            state.items = state.items.filter(i => i.id !== item.id);
            updateStatusLabel();
          } else {
            card.className = `card ${item.is_read ? 'read' : 'unread'}`;
            card.querySelector(".btnRead").textContent = item.is_read ? 'Mark unread' : 'Mark read';
          }
          loadMeta();
          loadFeeds();
        };

        card.querySelector(".btnStar").onclick = async (e) => {
          e.stopPropagation();
          const res = await api(`/api/items/${item.id}`, { method: "PATCH", body: JSON.stringify({ is_starred: !item.is_starred }) });
          item.is_starred = res.is_starred;
          card.querySelector(".btnStar").textContent = item.is_starred ? '★ Starred' : '☆ Star';
          loadMeta();
        };

        grid.appendChild(card);
      });
    }

    async function showHealth() {
      state.mode = "health";
      el("grid").classList.add("hidden");
      el("healthPanel").classList.remove("hidden");
      el("status").textContent = "Loading feed health diagnostic analytics…";
      
      state.health = await api(`/api/health?profile_id=${state.currentProfileId}`);
      el("status").textContent = `Feed Health Check — ${state.health.length} monitored paths`;
      let h = `<table class="healthTable">
        <thead>
          <tr><th>Feed Stream / Group</th><th>Status</th><th>Checked</th><th>Telemetry / Issue Log</th></tr>
        </thead>
        <tbody>`;
      state.health.forEach(f => {
        const st = f.status === 'error' ? '❌ Issue' : '✔ Healthy';
        h += `<tr>
          <td><strong>${esc(f.title)}</strong><br/><small class="muted">${esc(f.category)}</small></td>
          <td><span class="statusBadge ${f.status}">${st}</span></td>
          <td>${fmtDate(f.last_checked)}</td>
          <td><small>${esc(f.last_error || 'Active connection healthy')}</small></td>
        </tr>`;
      });
      h += `</tbody></table>`;
      el("healthPanel").innerHTML = h;
    }

    window.triggerOpmlImport = async function() {
      const fileInput = document.getElementById("opmlFileInput");
      if (!fileInput.files.length) return alert("Please select an OPML file to import.");
      
      const formData = new FormData();
      formData.append("file", fileInput.files[0]);
      
      el("status").textContent = "Uploading and parsing OPML data...";
      try {
        const response = await fetch(`/api/profiles/${state.currentProfileId}/import`, {
          method: "POST",
          body: formData
        });
        if (!response.ok) throw new Error(await response.text());
        const res = await response.json();
        alert(`Import processed successfully.\nTotal feeds detected: ${res.total_found}\nNewly added configurations: ${res.newly_added}`);
        await loadFeeds();
        await loadMeta();
        showManageFeeds();
      } catch (err) {
        console.error(err);
        alert(`Failed to import OPML content: ${err.message}`);
        el("status").textContent = "OPML Import execution failed.";
      }
    };

    window.triggerOpmlExport = function() {
      window.location.href = `/api/profiles/${state.currentProfileId}/export`;
    };

    function showManageFeeds() {
      state.mode = "manage";
      el("grid").classList.add("hidden");
      el("healthPanel").classList.remove("hidden");
      el("status").textContent = "Profile Feed Configuration Manager";

      let h = `<div class="manage-forms" style="margin-bottom: 25px; padding: 20px; background: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; display: flex; flex-direction: column; gap: 20px;">
        <div style="display: flex; flex-direction: column; gap: 10px;">
          <h4 style="font-weight: 800;">Add New Feed Stream to Current Profile</h4>
          <div style="display: flex; flex-wrap: wrap; gap: 10px;">
            <input id="newFeedTitle" placeholder="Feed Title" type="text" />
            <input id="newFeedCat" placeholder="Category" type="text" />
            <input id="newFeedXml" placeholder="XML Feed URL" type="text" style="flex: 1; min-width: 250px;" />
            <button id="submitNewFeedBtn">Add Stream</button>
          </div>
        </div>
        <hr style="border: 0; border-top: 1px solid var(--border);" />
        <div style="display: flex; flex-direction: column; gap: 10px;">
          <h4 style="font-weight: 800;">Create New Isolated Profile</h4>
          <div style="display: flex; gap: 10px;">
            <input id="newProfileName" placeholder="New Profile Name" type="text" style="flex: 1;" />
            <button id="submitNewProfileBtn" class="secondary">Create Profile</button>
          </div>
        </div>
        <hr style="border: 0; border-top: 1px solid var(--border);" />
        <div style="display: flex; flex-direction: column; gap: 12px;">
          <h4 style="font-weight: 800;">OPML Data Portability (Import / Export)</h4>
          <div style="display: flex; align-items: center; flex-wrap: wrap; gap: 15px; background: #1e293b; padding: 12px; border-radius: 6px; border: 1px solid var(--border);">
            <div style="display: flex; flex-direction: column; gap: 4px;">
              <span style="font-size: 0.8rem; font-weight: bold; color: var(--text-muted);">Import OPML XML File:</span>
              <input type="file" id="opmlFileInput" accept=".opml,.xml" style="font-size: 0.85rem;" />
            </div>
            <button id="importOpmlBtn" style="padding: 6px 14px;" onclick="triggerOpmlImport()">Upload & Merge</button>
            <div style="margin-left: auto; display: flex; flex-direction: column; gap: 4px; align-items: flex-end;">
              <span style="font-size: 0.8rem; font-weight: bold; color: var(--text-muted);">Backup context:</span>
              <button id="exportOpmlBtn" class="secondary" style="padding: 6px 14px;" onclick="triggerOpmlExport()">Download Profile OPML</button>
            </div>
          </div>
        </div>
      </div>`;
      h += `<table class="healthTable">
        <thead><tr><th>Title</th><th>Category</th><th>XML Stream URL</th><th>Actions</th></tr></thead>
        <tbody>`;
      state.feeds.forEach(f => {
        h += `<tr>
          <td><strong>${esc(f.title)}</strong></td>
          <td>${esc(f.category)}</td>
          <td><small>${esc(f.xml_url)}</small></td>
          <td>
            <button class="secondary" style="padding: 4px 8px; font-size: 0.75rem;" onclick="openEditFeedModal(${f.id})">Modify</button>
            <button class="secondary" style="padding: 4px 8px; font-size: 0.75rem; color: var(--danger);" onclick="deleteFeedItem(${f.id})">Remove</button>
          </td>
        </tr>`;
      });
      h += `</tbody></table>`;
      el("healthPanel").innerHTML = h;

      el("submitNewFeedBtn").onclick = async () => {
        const title = el("newFeedTitle").value;
        const category = el("newFeedCat").value;
        const xml_url = el("newFeedXml").value;
        if(!title || !xml_url) return alert("Title and XML Url fields are required.");
        await api(`/api/feeds?profile_id=${state.currentProfileId}`, { method: "POST", body: JSON.stringify({ title, category, xml_url }) });
        await loadFeeds(); loadMeta(); showManageFeeds();
      };
      el("submitNewProfileBtn").onclick = async () => {
        const name = el("newProfileName").value;
        if(!name) return alert("Profile name required.");
        const p = await api("/api/profiles", { method: "POST", body: JSON.stringify({ name }) });
        state.currentProfileId = p.id;
        await loadProfiles(); await loadMeta(); await loadFeeds(); showManageFeeds();
      };
    }

    window.openEditFeedModal = function(feedId) {
      const f = state.feeds.find(feed => feed.id === feedId);
      if(!f) return;
      el("modalTitle").textContent = "Edit Feed Subscription";
      el("modalBody").innerHTML = `
        <label style="display:block; margin-bottom:12px;">
          <span style="font-size:0.85rem; color:var(--text-muted); font-weight:700;">Feed Title</span>
          <input id="editFeedTitle" type="text" value="${esc(f.title)}" style="width:100%; padding:8px; margin-top:4px; background:#1e293b; color:#fff; border:1px solid var(--border); border-radius:6px;"/>
        </label>
        <label style="display:block; margin-bottom:12px;">
          <span style="font-size:0.85rem; color:var(--text-muted); font-weight:700;">Category</span>
          <input id="editFeedCat" type="text" value="${esc(f.category)}" style="width:100%; padding:8px; margin-top:4px; background:#1e293b; color:#fff; border:1px solid var(--border); border-radius:6px;"/>
        </label>
        <label style="display:block; margin-bottom:12px;">
          <span style="font-size:0.85rem; color:var(--text-muted); font-weight:700;">XML Url Stream</span>
          <input id="editFeedXml" type="text" value="${esc(f.xml_url)}" style="width:100%; padding:8px; margin-top:4px; background:#1e293b; color:#fff; border:1px solid var(--border); border-radius:6px;"/>
        </label>
      `;
      el("editModal").classList.remove("hidden");
      el("modalSaveBtn").onclick = async () => {
        await api(`/api/feeds/${feedId}`, {
          method: "PUT",
          body: JSON.stringify({ title: el("editFeedTitle").value, category: el("editFeedCat").value, xml_url: el("editFeedXml").value })
        });
        el("editModal").classList.add("hidden");
        await loadFeeds(); loadMeta(); showManageFeeds();
      };
    };

    window.deleteFeedItem = async function(feedId) {
      if(!confirm("Are you completely sure you want to remove this tracking stream?")) return;
      await api(`/api/feeds/${feedId}`, { method: "DELETE" });
      await loadFeeds(); loadMeta(); showManageFeeds();
    };

    window.addEventListener("scroll", () => {
      if (state.mode !== "stories" || !state.hasMore || state.loadingMore) return;
      if ((window.innerHeight + window.scrollY) >= (document.documentElement.scrollHeight - 600)) {
        loadMoreItems();
      }
    });

    el("profileSelect").onchange = async (ev) => {
      state.currentProfileId = parseInt(ev.target.value);
      state.category = ""; state.feedId = "";
      await loadMeta(); await loadFeeds();
      if(state.mode === "stories") loadItems();
      else if(state.mode === "health") showHealth();
      else showManageFeeds();
    };

    el("category").onchange = ev => { state.category = ev.target.value; state.feedId = ""; renderFeedSelect(); loadItems(); };
    el("feed").onchange = ev => { state.feedId = ev.target.value; loadItems(); };
    el("search").oninput = ev => { state.q = ev.target.value.trim(); loadItems(); };
    el("unreadOnly").onchange = ev => { state.unreadOnly = ev.target.checked; loadItems(); };
    el("starredOnly").onchange = ev => { state.starredOnly = ev.target.checked; loadItems(); };
    el("homeBtn").onclick = () => { state.category = ""; state.feedId = ""; state.securityDigest = false; el("category").value = ""; el("digestBtn").classList.remove("active"); renderFeedSelect(); loadItems(); };
    el("digestBtn").onclick = () => { state.securityDigest = !state.securityDigest; el("digestBtn").classList.toggle("active", state.securityDigest); loadItems(); };
    el("healthBtn").onclick = () => { if(state.mode === "health") loadItems(); else showHealth(); };
    el("manageFeedsBtn").onclick = () => { if(state.mode === "manage") loadItems(); else showManageFeeds(); };
    el("modalCancelBtn").onclick = () => el("editModal").classList.add("hidden");
    
    el("stats").onclick = () => {
      if (state.meta && state.meta.error_count > 0) {
        showHealth();
      }
    };

    el("markReadBtn").onclick = async () => {
      await api(`/api/items/mark-all-read?profile_id=${state.currentProfileId}${state.category ? `&category=${encodeURIComponent(state.category)}` : ''}${state.feedId ? `&feed_id=${state.feedId}` : ''}`, { method: "POST" });
      await loadItems();
      await loadMeta();
      await loadFeeds();
    };

    el("refreshBtn").onclick = async () => {
      await api("/api/refresh", { method: "POST" });
      setTimeout(() => { loadMeta(); loadFeeds(); loadItems(); }, 1200);
    };

    async function initializeSystem() {
      await loadProfiles();
      await loadMeta();
      await loadFeeds();
      await loadItems();
    }
    initializeSystem();
  </script>
</body>
</html>
FRONTENDHTML

# -----------------------------------------------------------------
# Base CSS Stylesheet — app/static/styles.css
# -----------------------------------------------------------------
cat > app/static/styles.css <<'CSSEOF'
:root {
  --bg: #0f141c;
  --bg-card: #171f2b;
  --border: #243145;
  --text: #e2e8f0;
  --text-muted: #8a99ad;
  --accent: #3b82f6;
  --accent-hover: #2563eb;
  --danger: #ef4444;
}
* { box-sizing: border-box; margin: 0; padding: 0; }
body { background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; line-height: 1.5; padding-bottom: 40px; }
.hero { background: linear-gradient(135deg, #1e293b, #0f172a); border-bottom: 1px solid var(--border); padding: 30px 20px; display: flex; flex-wrap: wrap; justify-content: space-between; align-items: center; gap: 20px; }
.heroTitle h1 { font-size: 1.8rem; font-weight: 800; cursor: pointer; color: #fff; }
.heroTitle h1:hover { color: var(--accent); }
.muted { color: var(--text-muted); font-size: 0.9rem; margin-top: 4px; }
.heroActions { display: flex; gap: 10px; flex-wrap: wrap; }
button { background: var(--accent); color: white; border: none; padding: 8px 16px; font-weight: 600; border-radius: 6px; cursor: pointer; font-size: 0.9rem; transition: background 0.2s; }
button:hover { background: var(--accent-hover); }
button.secondary { background: #334155; color: #cbd5e1; }
button.secondary:hover { background: #475569; }
button.active { background: #059669 !important; }
main { max-width: 1200px; margin: 0 auto; padding: 20px; }
.controls { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; background: var(--bg-card); border: 1px solid var(--border); padding: 15px; border-radius: 8px; margin-bottom: 20px; }
input[type="search"], select, input[type="text"] { background: #1e293b; color: var(--text); border: 1px solid var(--border); padding: 8px 12px; border-radius: 6px; font-size: 0.9rem; outline: none; }
input[type="search"] { flex: 1; min-width: 200px; }
.toggle { display: flex; align-items: center; gap: 6px; cursor: pointer; font-size: 0.9rem; user-select: none; }
.status { font-size: 0.9rem; color: var(--text-muted); margin-bottom: 15px; font-weight: 500; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(340px, 1fr)); gap: 20px; transition: opacity 0.2s; }
.grid.loading { opacity: 0.5; pointer-events: none; }
.card { background: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; display: flex; flex-direction: column; transition: transform 0.2s, box-shadow 0.2s; }
.card:hover { transform: translateY(-2px); box-shadow: 0 8px 24px rgba(0,0,0,0.3); }
.card.read { opacity: 0.65; }
.cardImage { width: 100%; height: 180px; background: #1e293b; overflow: hidden; position: relative; border-bottom: 1px solid var(--border); }
.cardImage img { width: 100%; height: 100%; object-fit: cover; }
.cardBody { padding: 16px; display: flex; flex-direction: column; flex: 1; }
.cardMeta { display: flex; flex-wrap: wrap; gap: 6px; font-size: 0.75rem; font-weight: 700; text-transform: uppercase; margin-bottom: 10px; }
.categoryTag { color: var(--accent); }
.feedTitleTag { color: #e11d48; max-width: 150px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.authorTag { color: var(--text-muted); }
.cardTitle { font-size: 1.1rem; font-weight: 700; margin-bottom: 10px; line-height: 1.4; }
.cardTitle a { color: #fff; text-decoration: none; }
.cardTitle a:hover { color: var(--accent); text-decoration: underline; }
.cardTeaser { font-size: 0.9rem; color: var(--text-muted); margin-bottom: 15px; display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; flex: 1; }
.cardTime { font-size: 0.8rem; color: var(--text-muted); margin-top: auto; padding-top: 10px; border-top: 1px solid rgba(255,255,255,0.05); }
.cardActions { display: flex; gap: 8px; margin-top: 10px; }
.cardActions button { padding: 4px 8px; font-size: 0.75rem; border-radius: 4px; }
.healthPanel { background: var(--bg-card); border: 1px solid var(--border); border-radius: 8px; padding: 20px; overflow-x: auto; }
.healthTable { width: 100%; border-collapse: collapse; text-align: left; font-size: 0.9rem; }
.healthTable th, .healthTable td { padding: 12px; border-bottom: 1px solid var(--border); }
.healthTable th { background: #1e293b; font-weight: 600; color: #fff; }
.statusBadge { padding: 2px 6px; font-size: 0.75rem; font-weight: bold; border-radius: 4px; }
.statusBadge.healthy { background: rgba(16,185,129,0.2); color: #10b981; }
.statusBadge.error { background: rgba(239,68,68,0.2); color: #ef4444; }
.hidden { display: none !important; }
.modal { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.75); display: flex; align-items: center; justify-content: center; z-index: 1000; }
.modal-content { background: var(--bg-card); border: 1px solid var(--border); padding: 25px; border-radius: 8px; width: 100%; max-width: 500px; }
.modal-content h3 { margin-bottom: 15px; }
.modal-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 20px; }
CSSEOF

# -----------------------------------------------------------------
# Stack Deployment Execution
# -----------------------------------------------------------------
echo "================================================"
echo "Starting Stack Container Layer Rebuild..."
echo "================================================"
docker compose down
docker compose up -d --build

cat <<EOF

=================================================================
DEPLOYMENT COMPLETE
=================================================================
URL: https://${TS_HOSTNAME}

COMMAND REF SHEET
-----------------
  Stop:    docker compose down
  Start:   docker compose up -d
  Rebuild: docker compose up -d --build
  Refresh: curl -X POST https://${TS_HOSTNAME}/api/refresh
  Backup:  cp data/opml_reader.sqlite3 "data/opml_reader.\$(date +%F).sqlite3"

EDIT FEEDS & PROFILES
---------------------
  Profiles and custom subscriptions are now handled via the UI 
  ("Manage feeds" configuration engine view).
  Your first profile is automatically initialized as 'Default'
  and pre-seeded directly from your source OPML collection structure.

DB PRUNING (weekly cron recommended)
--------------------------------------
  bash scripts/prune_db.sh
  Cron: 0 4 * * 0 bash \${PROJECT_DIR}/scripts/prune_db.sh >> \${PROJECT_DIR}/data/prune.log 2>&1

CERT RENEWAL (Tailscale certs last 90 days)
--------------------------------------------
  sudo bash scripts/renew_certs.sh
  Cron: 0 3 * * * bash \${PROJECT_DIR}/scripts/renew_certs.sh >> \${PROJECT_DIR}/data/cert_renewal.log 2>&1
  sudoers rule for tailscale cert and chmod:
    lee ALL=(root) NOPASSWD: /usr/bin/tailscale cert *, /bin/chmod *

OPTIONAL FIREWALL HARDENING
----------------------------
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow in on tailscale0 to any port 443 proto tcp
  sudo ufw allow in on tailscale0 to any port 80 proto tcp
  sudo ufw allow OpenSSH
  sudo ufw enable
EOF

echo "================================================"
echo "Setup Script Terminated Cleanly."
echo "================================================"
