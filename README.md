# Lee's Feeds

A self-hosted RSS reader deployed as a single script into Docker, with private access via Tailscale and automatic TLS via Caddy.

---

A long, long time ago in a galaxy far, far away, I used Google Reader. Nothing since has ticked the box — Flipboard came close, but why is there so much Australian content in there?!

So I built Lee's Feeds. One script, one host, done.

It comes with some starter feeds you might think are rubbish. That's fine — delete them. You can create profiles, and import/export OPML files from the Manage Feeds panel.

> ⚠️ No authentication — this is a single-user application, designed to run privately over Tailscale.

## Requirements

- A Linux host (VM or bare metal)
- [Tailscale](https://tailscale.com) installed and authenticated
- Docker and Docker Compose

## Quick start

1. Run bootstrap.sh:

```bash
bash bootstrap.sh
```

3. Point your browser at your Tailscale hostname (it should have detected it automagically)

That's it.

## First run

```bash
cd leesfeeds
docker compose up -d --build
```

## Upgrading

```bash
cd leesfeeds
docker compose down
docker compose up -d --build
```

## Screenshot

<img width="1017" alt="Lee's Feeds screenshot" src="https://github.com/user-attachments/assets/05f87593-e831-496f-b1de-fd4132cac14d" />
