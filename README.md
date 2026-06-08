# Lee's Feeds
A docker-based RSS collector based on Tailscale, Caddy and other freely-available components

A long, long time ago in a galaxy far, far away, I used Google Reader.
Nothing since then has ticked the box - Flipboard maybe coming close but why do I have Australian stuff in there all the time?!!?

So Lee's Feeds is my creation; it's a one-script deploy into Docker using Tailscale to build a private network and have TLS.

It comes with some feeds that you might think are rubbish.  OK!  Just delete them.
You can also create profiles (heck, it's a one-person application - no authentication!) and import/export OPML files there.

Take bootstrap.sh, modify your Tailscale hostname into it and run it on a linux host.  It will search dependencies and install itself,
all you need to do is point your browser at it.
