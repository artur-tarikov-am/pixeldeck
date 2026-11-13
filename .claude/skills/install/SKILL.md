---
name: install
description: Build Pixeldeck and install it on this Mac (the hub and the notch). Use when asked to install, reinstall, deploy or update the app — "установи", "поставь на мак", "поставь в чёлку", "обнови приложение", "пересобери и поставь".
---

# Install Pixeldeck

Run `mac/install.sh` from the repository root, with a timeout of several minutes. The app with the hub and the notch restarts, and Claude events sent meanwhile are lost.

## Check the result

Report what you saw, and name whatever you could not check.

    curl -s -m 2 127.0.0.1:7777/health
    lsof -nP -iTCP:7777 -sTCP:LISTEN

`health` must answer `{"ok":true}` and the listener must be `Pixeldeck` on `127.0.0.1`. If it fails, read `~/.pixeldeck/hub.log`.

The notch must be connected to the hub over loopback. Whether it looks right only the user can tell: screenshots are not available to the agent.

    netstat -an -p tcp | grep '127.0.0.1.7777 ' | grep ESTABLISHED
