#!/usr/bin/env python3
import json, sys, os, subprocess, time
from datetime import datetime

data = json.load(sys.stdin)

# ── ANSI helpers ──────────────────────────────────────────────
def rgb(r, g, b): return f'\033[38;2;{r};{g};{b}m'
CYAN    = '\033[36m'
GREEN   = '\033[32m'
YELLOW  = '\033[33m'
RED     = '\033[31m'
MAGENTA = '\033[35m'
DIM     = '\033[2m'
BOLD    = '\033[1m'
RESET   = '\033[0m'
SEP     = f' {DIM}|{RESET} '

# ── Model ─────────────────────────────────────────────────────
model = (data.get('model') or {}).get('display_name') or 'unknown'

# ── Session duration (prefer cost.total_duration_ms) ─────────
duration = ''
ms = ((data.get('cost') or {}).get('total_duration_ms') or 0)
if ms:
    secs = int(ms / 1000)
    h, m = secs // 3600, (secs % 3600) // 60
    duration = f'{h}h{m}m' if h > 0 else f'{m}m'
else:
    transcript = data.get('transcript_path') or ''
    if transcript and os.path.exists(transcript):
        try:
            st = os.stat(transcript)
            birth = getattr(st, 'st_birthtime', None) or st.st_ctime
            elapsed = int(time.time() - birth)
            h, m = elapsed // 3600, (elapsed % 3600) // 60
            duration = f'{h}h{m}m' if h > 0 else f'{m}m'
        except OSError:
            pass

# ── Git repo + branch ─────────────────────────────────────────
cwd = (data.get('workspace') or {}).get('current_dir') or data.get('cwd') or ''
repo = branch = ''
if cwd:
    try:
        branch = subprocess.check_output(
            ['git', '-C', cwd, '--no-optional-locks', 'symbolic-ref', '--short', 'HEAD'],
            stderr=subprocess.DEVNULL).decode().strip()
        toplevel = subprocess.check_output(
            ['git', '-C', cwd, '--no-optional-locks', 'rev-parse', '--show-toplevel'],
            stderr=subprocess.DEVNULL).decode().strip()
        repo = os.path.basename(toplevel)
    except Exception:
        pass

# ── Context bar: 20-block RGB gradient ───────────────────────
BAR_WIDTH = 20
used = (data.get('context_window') or {}).get('used_percentage')
if used is not None:
    used_int = round(used)
    filled = round(used_int * BAR_WIDTH / 100)
    bar = ''
    for i in range(BAR_WIDTH):
        pos = i * 100 // (BAR_WIDTH - 1)
        if pos <= 50:
            r, g, b = round(220 * pos / 50), 200, round(80 - 80 * pos / 50)
        else:
            adj = pos - 50
            r, g, b = 220, round(200 - 160 * adj / 50), round(20 * adj / 50)
        bar += f'{rgb(r,g,b)}█' if i < filled else '\033[38;2;60;60;60m░'
    bar += RESET

    if   used_int >= 90: emoji, pct_color = '🚨', RED
    elif used_int >= 70: emoji, pct_color = '🔥', YELLOW
    elif used_int >= 20: emoji, pct_color = '⚡', GREEN
    else:                emoji, pct_color = '🟢', GREEN

    ctx = f'{emoji} {bar} {pct_color}{used_int}%{RESET}'
else:
    ctx = f'🟢 \033[38;2;60;60;60m{"░" * BAR_WIDTH}{RESET} --%'

# ── Rate limits ───────────────────────────────────────────────
def rate_color(pct):
    if pct >= 90: return RED
    if pct >= 70: return YELLOW
    return GREEN

def time_until(ts):
    remaining = int(ts - time.time())
    if remaining <= 0: return 'now'
    h, m = remaining // 3600, (remaining % 3600) // 60
    return f'{h}h{m:02d}m' if h > 0 else f'{m}m'

rate      = data.get('rate_limits') or {}
five      = rate.get('five_hour') or {}
week      = rate.get('seven_day') or {}
five_pct  = five.get('used_percentage')
week_pct  = week.get('used_percentage')
five_reset = five.get('resets_at')
week_reset = week.get('resets_at')

# ── Assemble ──────────────────────────────────────────────────
parts = []
if repo:   parts.append(f'{BOLD}{YELLOW}{repo}{RESET}')
if branch: parts.append(f'{BOLD}{CYAN}🌿 ({branch}){RESET}')
parts.append(ctx)
if duration:  parts.append(duration)
if five_pct is not None:
    c = rate_color(five_pct)
    reset_str = f' {DIM}↺{time_until(five_reset)}{RESET}' if five_reset else ''
    parts.append(f'5h:{c}{round(five_pct)}%{RESET}{reset_str}')
if week_pct is not None:
    c = rate_color(week_pct)
    if week_reset:
        dt = datetime.fromtimestamp(week_reset)
        reset_str = f' {DIM}↺{time_until(week_reset)} ({dt.strftime("%a %H:%M")}){RESET}'
    else:
        reset_str = ''
    parts.append(f'7d:{c}{round(week_pct)}%{RESET}{reset_str}')
parts.append(f'{MAGENTA}🤖 {model}{RESET}')

print(SEP.join(parts), end='')
