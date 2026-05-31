#!/usr/bin/env python3.11
"""Dump all CGWindowList windows for Claude Desktop (or all apps if no arg).
Run while a Claude Desktop permission dialog is on screen to get real QuickWindow geometry.

Usage:
  python3 dump_windows.py          # all windows
  python3 dump_windows.py claude   # only Claude Desktop windows
  python3 dump_windows.py watch    # poll every 0.5s, print new windows as they appear
"""
import sys, time, Quartz

CLAUDE_BUNDLE = "com.anthropic.claudefordesktop"

def get_windows(filter_claude=False):
    opts = Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements
    wins = Quartz.CGWindowListCopyWindowInfo(opts, Quartz.kCGNullWindowID)
    result = []
    for w in (wins or []):
        owner = w.get("kCGWindowOwnerName", "?")
        pid   = w.get("kCGWindowOwnerPID", 0)
        layer = w.get("kCGWindowLayer", -1)
        bounds = w.get("kCGWindowBounds", {})
        x, y   = bounds.get("X", 0), bounds.get("Y", 0)
        ww, wh = bounds.get("Width", 0), bounds.get("Height", 0)
        bundle = ""
        # CGWindowList doesn't expose bundle ID; identify Claude by owner name
        is_claude = "Claude" in owner
        if filter_claude and not is_claude:
            continue
        result.append((pid, layer, x, y, ww, wh, owner))
    return result

def fmt(wins):
    lines = []
    for pid, layer, x, y, w, h, owner in wins:
        tag = ""
        if "Claude" in owner and layer == 8 and w < 600 and h < 300:
            tag = "  ← QUICKWINDOW candidate"
        lines.append(f"  pid={pid:6d} layer={layer:3d}  {x:5.0f},{y:5.0f}  {w:5.0f}×{h:4.0f}  {owner}{tag}")
    return "\n".join(lines)

mode = sys.argv[1] if len(sys.argv) > 1 else "all"

if mode == "watch":
    print("Watching for new windows (Ctrl-C to stop)…")
    seen = set()
    try:
        while True:
            wins = get_windows(filter_claude=False)
            current = {(p, l, x, y, w, h) for p, l, x, y, w, h, _ in wins}
            new = current - seen
            if new:
                print(f"\n--- {time.strftime('%H:%M:%S')} ---")
                print(fmt(wins))
            seen = current
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
elif mode == "claude":
    print("Claude Desktop windows:")
    print(fmt(get_windows(filter_claude=True)) or "  (none)")
else:
    print("All on-screen windows:")
    print(fmt(get_windows(filter_claude=False)))
