# codex-auth Fedora Linux Setup

Auto-switch OpenAI accounts on Fedora with systemd daemon + health monitoring.

## Files

| File | Purpose |
|------|---------|
| `codex-auth-autoswitch.service` | systemd daemon: refreshes usage every ~60s, auto-switches on thresholds |
| `override.conf.d/override.conf` | Drop-in: sets `Restart=always`, `RestartSec=5`, `StartLimitBurst=10` |
| `codex-auth-health.{service,timer}` | Timer runs every 30min; oneshot calls the health script |
| `codex-auth-health.sh` | Installed to `~/.local/bin/codex-auth-health` |

## Quick Install

### 1. systemd daemon

```bash
cp codex-auth-autoswitch.service ~/.config/systemd/user/
mkdir -p ~/.config/systemd/user/codex-auth-autoswitch.service.d
cp override.conf.d/override.conf ~/.config/systemd/user/codex-auth-autoswitch.service.d/
systemctl --user daemon-reload
systemctl --user enable --now codex-auth-autoswitch.service
```

### 2. Health check (30min interval)

```bash
cp codex-auth-health.sh ~/.local/bin/codex-auth-health
chmod +x ~/.local/bin/codex-auth-health
cp codex-auth-health.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now codex-auth-health.timer
```

### 3. Log rotation

```bash
# ~/.config/logrotate/codex-auth
/tmp/codex-auth-daemon.log
/tmp/codex-auth-health.log {
  rotate 7
  daily
  compress
  missingok
}
```

Add crontab: `10 0 * * * /usr/sbin/logrotate ~/.config/logrotate/codex-auth --state /tmp/logrotate.state`

## Health Script Behaviour

- Checks daemon is alive every 30min; restarts if dead
- Scans all token life; removes expired accounts
- Deletes `.bak*` files before `import --purge` to prevent zombie re-import
- Rotates active account when <24h remaining
- Detects 401 spikes (>3 in 15min) → force rotation + daemon restart
- Warns when pool drops below 48h/12h thresholds
