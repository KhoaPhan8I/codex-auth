#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/tmp/codex-auth-health.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')
NOW_EPOCH=$(date +%s)
AUTH_DIR="$HOME/.codex/accounts"
SERVICE="codex-auth-autoswitch.service"

{
  echo "[$DATE] === codex-auth health ==="

  # 1. Daemon alive?
  if ! systemctl --user is-active --quiet "$SERVICE"; then
    echo "[WARN] Daemon down! Restarting..."
    systemctl --user start "$SERVICE" && echo "[OK] Daemon restarted"
  fi

  # 2. Scan all tokens: classify by remaining life
  BEST_EMAIL=""
  BEST_REMAIN=0
  CURRENT_EMAIL=""
  CURRENT_REMAIN=-1
  POOL_48H=0
  POOL_24H=0
  POOL_12H=0
  EXPIRED_LIST=()

  for f in "$AUTH_DIR"/*.auth.json; do
    [ -f "$f" ] || continue
    DATA=$(python3 -c "
import sys,json,base64,time
try:
    d = json.load(open('$f'))
    t = d.get('tokens',{})
    at = t.get('access_token','')
    if not at: sys.exit(0)
    p = at.split('.')[1]
    pad = 4 - len(p) % 4
    if pad != 4: p += '=' * pad
    j = json.loads(base64.urlsafe_b64decode(p))
    exp = j.get('exp', 0)
    it = t.get('id_token','')
    em = 'unknown'
    if it:
        ip = it.split('.')[1]
        pad = 4 - len(ip) % 4
        if pad != 4: ip += '=' * pad
        ij = json.loads(base64.urlsafe_b64decode(ip))
        em = ij.get('email','unknown')
    aid = j.get('https://api.openai.com/auth',{}).get('chatgpt_account_id','')
    remain = exp - int(time.time())
    print(f'{em}|{exp}|{remain}|{aid}')
except:
    sys.exit(1)
" 2>/dev/null || true)

    [ -z "$DATA" ] && continue
    EMAIL=$(echo "$DATA" | cut -d'|' -f1)
    EXP=$(echo "$DATA" | cut -d'|' -f2)
    REMAIN=$(echo "$DATA" | cut -d'|' -f3)
    AID=$(echo "$DATA" | cut -d'|' -f4)

    if [ "$REMAIN" -le 0 ] 2>/dev/null; then
      EXPIRED_LIST+=("$EMAIL|$f")
      continue
    fi

    REM_H=$(( REMAIN / 3600 ))
    [ "$REM_H" -ge 48 ] && POOL_48H=$((POOL_48H+1))
    [ "$REM_H" -ge 24 ] && POOL_24H=$((POOL_24H+1))
    [ "$REM_H" -ge 12 ] && POOL_12H=$((POOL_12H+1))

    if [ "$REMAIN" -gt "$BEST_REMAIN" ] 2>/dev/null; then
      BEST_REMAIN=$REMAIN
      BEST_EMAIL="$EMAIL"
    fi
  done

  # 3. Get current active account & its remaining time
  CURRENT_EMAIL=$(codex-auth status 2>/dev/null | grep 'active account:' | awk '{print $NF}')
  CURRENT_REMAIN=$(python3 -c "
import os,json,base64,glob,time
auth_dir = '$AUTH_DIR'
target = '$CURRENT_EMAIL'
for f in glob.glob(auth_dir + '*.auth.json'):
    try:
        d = json.load(open(f))
        it = d.get('tokens',{}).get('id_token','')
        if not it: continue
        ip = it.split('.')[1]
        pad = 4 - len(ip) % 4
        if pad != 4: ip += '=' * pad
        ij = json.loads(base64.urlsafe_b64decode(ip))
        if ij.get('email','') == target:
            at = d.get('tokens',{}).get('access_token','')
            if at:
                ap = at.split('.')[1]
                pad = 4 - len(ap) % 4
                if pad != 4: ap += '=' * pad
                aj = json.loads(base64.urlsafe_b64decode(ap))
                print((aj.get('exp',0) - int(time.time())) // 3600)
            break
    except: pass
" 2>/dev/null || echo 0)

  echo "[POOL] accounts: ${#EXPIRED_LIST[@]} expired | ${POOL_48H}+48h | ${POOL_24H}+24h | ${POOL_12H}+12h"
  echo "[ACTIVE] ${CURRENT_EMAIL:-none} | ${CURRENT_REMAIN:-0}h remaining"
  echo "[BEST] ${BEST_EMAIL:-none} | $(( BEST_REMAIN / 3600 ))h remaining"

  # 4. Always purge .bak files before import (prevent zombie re-import)
  rm -f "$AUTH_DIR"/*.bak* 2>/dev/null

  # 5. Remove expired accounts
  if [ ${#EXPIRED_LIST[@]} -gt 0 ]; then
    for ENTRY in "${EXPIRED_LIST[@]}"; do
      EMAIL="${ENTRY%%|*}"
      FILE="${ENTRY#*|}"
      echo "[EXPIRED] Removing $EMAIL"
      codex-auth remove "$EMAIL" 2>/dev/null || true
      rm -f "$FILE" 2>/dev/null || true
    done
    codex-auth import --purge >/dev/null 2>&1 || true
    echo "[CLEANUP] Removed ${#EXPIRED_LIST[@]} expired, registry rebuilt"
  fi

  # 6. Proactive rotation: if current account has <24h or is expired
  NEED_SWITCH=false
  if [ "$CURRENT_REMAIN" -lt 24 ] 2>/dev/null && [ -n "$BEST_EMAIL" ]; then
    echo "[ROTATE] Current <24h left! Switching to $BEST_EMAIL ($(( BEST_REMAIN / 3600 ))h)"
    codex-auth switch "$BEST_EMAIL" 2>/dev/null && NEED_SWITCH=true
  fi

  # 7. If pool is running low, warn
  if [ "$POOL_48H" -le 3 ] 2>/dev/null; then
    echo "[ALERT] Only $POOL_48H accounts with >48h remaining! Prepare to login new accounts soon."
  fi
  if [ "$POOL_12H" -le 2 ] 2>/dev/null; then
    echo "[CRITICAL] Only $POOL_12H accounts with >12h remaining! Immediate login needed!"
  fi

  # 7. Check daemon for 401 errors (session dead without us detecting)
  ERR_401=$(journalctl --user -u "$SERVICE" --since "15 min ago" --no-pager 2>&1 | grep -c "status=401" || true)
  if [ "$ERR_401" -gt 3 ]; then
    echo "[WARN] ${ERR_401}x 401 in 15min! Forcing rotation..."
    codex-auth switch --best 2>/dev/null || true
    systemctl --user restart "$SERVICE" 2>/dev/null || true
  fi

  # 8. If we rotated, restart daemon to pick up new active account
  if [ "$NEED_SWITCH" = true ]; then
    systemctl --user restart "$SERVICE" 2>/dev/null || true
    echo "[OK] Daemon restarted after rotation"
  fi

  # 9. Daemon healthy?
  if systemctl --user is-active --quiet "$SERVICE"; then
    echo "[OK] Daemon healthy"
  fi

  echo "[$DATE] Done"
} >> "$LOG_FILE" 2>&1

tail -200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
