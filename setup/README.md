# codex-auth Fedora Linux Setup

Auto-switch OpenAI/ChatGPT accounts on Fedora with systemd daemon + health monitoring.

## Architecture

```
codex-auth-autoswitch.service (daemon)
  └── refreshes usage every ~60s via API (https://chatgpt.com/backend-api/wham/usage)
  └── auto-switches when 5h or weekly thresholds exceeded
  └── systemd manages: Restart=always, RestartSec=5

codex-auth-health.timer (every 30min)
  └── activates codex-auth-health.service (oneshot)
      └── codex-auth-health.sh:
          ├── [1] Ensure daemon alive → restart if dead
          ├── [2] Scan all tokens → classify by remaining life
          ├── [3] Remove expired accounts → purge .bak → import --purge
          ├── [4] Proactive rotation → if current < 24h, switch to best
          ├── [5] 401 spike detection → force rotation + daemon restart
          ├── [6] Registry ↔ auth.json sync → prevent "unknown email" in codext
          └── [7] Pool depletion alerts

logrotate (daily via cron)
  └── /tmp/codex-auth-daemon.log
  └── /tmp/codex-auth-health.log
```

## Data Flow

```
  ┌──────────────────────────┐
  │  ~/.codex/auth.json      │  ───  Active session tokens (what Codex uses)
  ├──────────────────────────┤
  │  ~/.codex/accounts/      │
  │  ├── registry.json       │  ───  Account index (schema v3)
  │  ├── <base64>.auth.json  │  ───  Per-account token files (19-20 files)
  │  └── *.bak               │  ───  Auto-deleted before import --purge
  └──────────────────────────┘

  Switch flow:
    codex-auth switch <email>
      → reads ~/.codex/accounts/<hash>.auth.json
      → overwrites ~/.codex/auth.json
      → updates registry.json active_account_key
      → codext detects inotify change on auth.json → reloads

  Registry rebuild (after expiry cleanup):
    codex-auth import --purge
      → scans ~/.codex/accounts/*.auth.json
      → rebuilds registry.json
      → BUT may set active_account_key to a DIFFERENT account
      → HEALTH SCRIPT detects mismatch → issues switch to sync
```

## Files

| File | Purpose |
|------|---------|
| `codex-auth-autoswitch.service` | systemd daemon: refreshes usage every ~60s, auto-switches on thresholds |
| `override.conf.d/override.conf` | Drop-in: overrides system-wide `Restart=on-failure` → `Restart=always` |
| `codex-auth-health.{service,timer}` | Timer runs every 30min; oneshot calls the health script |
| `codex-auth-health.sh` | Multifunction health monitor (installed to `~/.local/bin/codex-auth-health`) |

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

Create `~/.config/logrotate/codex-auth`:

```
/tmp/codex-auth-daemon.log
/tmp/codex-auth-health.log {
  rotate 7
  daily
  compress
  missingok
}
```

Add crontab: `10 0 * * * /usr/sbin/logrotate ~/.config/logrotate/codex-auth --state /tmp/logrotate.state`

## Health Script Details

### Token Scan (`[2]`)
Iterates `~/.codex/accounts/*.auth.json`, decodes each JWT access token's payload, extracts email + expiry + account_id. Classifies:
- Expired (≤0h) → removal queue
- 12h+ → safe pool
- 24h+ → ready pool
- 48h+ → deep pool

### Expiry Cleanup (`[3]`)
- Removes expired accounts via `codex-auth remove <email>`
- Deletes `.bak*` files before `import --purge` to prevent zombie re-import
- Registry is rebuilt from scratch

### Proactive Rotation (`[4]`)
If current active account has <24h remaining, switches to the account with the most remaining time.

### 401 Detection (`[5]`)
Queries `journalctl --user -u codex-auth-autoswitch.service --since "15 min ago"` for `status=401`. If >3 hits:
- Forces `codex-auth switch --best`
- Restarts daemon

### Registry Sync (`[6]`)
Compares `auth.json` email vs `registry.json active_account_key` email. If mismatch (caused by `import --purge` changing registry key without updating `auth.json`), issues `codex-auth switch` to re-sync. Prevents codext showing `"unknown email"`.

### Pool Alerts (`[7]`)
- `[ALERT]` when <4 accounts with >48h remaining
- `[CRITICAL]` when <3 accounts with >12h remaining

## Maintenance

### Check health log
```bash
tail -20 /tmp/codex-auth-health.log
```

### Check daemon log
```bash
journalctl --user -u codex-auth-autoswitch.service --since "1 hour ago" --no-pager | grep -E "status=200|status=401"
```

### Next timer run
```bash
systemctl --user list-timers --no-pager | grep codex-auth
```

### Force health check
```bash
systemctl --user start codex-auth-health.service
```

## Known Issues

- **Registry drift**: `import --purge` can set `active_account_key` to a stale account. Health script auto-fixes it.
- **401 false positive**: Historical 401s in journal from old daemon instances can trigger rotation on first run after restart (resolves automatically after 15min).
- **Token expiry without warm**: All accounts have `refresh_token` + `offline_access` scope, but `codex-auth warm` requires a GUI session (`NoUsableWindows`). Accounts expire after ~9 days regardless.
