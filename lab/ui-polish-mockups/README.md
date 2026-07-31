# Live View chrome polish — A2 mockups

Static HTML prototypes for the **A2 · Grouped display drawer** redesign. Not wired into LuCI.

## Serve locally

```sh
python3 -m http.server 8765 --directory lab/ui-polish-mockups
# open http://localhost:8765/a2-chosen.html
```

## Chosen direction (locked)

| Decision | Choice |
|----------|--------|
| Layout | Watch strip → Display options (grouped) → Find row → table |
| Drawer | **A2 Grouped**: Live · Row look · Filters look |
| Default | Drawer **closed** |
| Auto-refresh | **Pause/Resume only** on strip (no checkbox) |
| Enable logging | Only filled button when logging is off |
| Table / filters | Location and behavior unchanged |

## Files

| File | Role |
|------|------|
| `a2-chosen.html` | **Canonical prototype** (+ scene switcher) |
| `a-explore.html` | A1/A2/A3 + scenes (history) |
| `a-display-drawer.html` / `b-*` / `c-*` | Earlier brainstorm |
| `index.html` | Index |

## Theme acceptance (implementation)

See the tracking GitHub issue. Must verify Bootstrap, Bootstrap dark/light if present, and Material via `./scripts/qemu-theme-tint-smoke.sh` plus a short chrome smoke (drawer + strip readable, no broken layout).
