# Live View chrome polish — A2 mockup

Locked static prototype for **[#77](https://github.com/lucas-albers-lz4/fwlive/issues/77)**. Not wired into LuCI.

## Serve

```sh
python3 -m http.server 8765 --directory lab/ui-polish-mockups
# open http://localhost:8765/a2-chosen.html
```

## Locked decisions

| Decision | Choice |
|----------|--------|
| Layout | Watch strip → Display options (grouped) → Find row → table |
| Drawer | **A2 Grouped**: Live · Row look · Filters look |
| Default | Drawer **closed** |
| Live updates | **Pause / Resume** on strip only (no Auto-refresh checkbox) |
| Enable logging | Only filled button when logging is off |
| Table / filters | Location and behavior unchanged |

## Files

- `a2-chosen.html` / `.css` / `.js` — canonical prototype (+ scene switcher)

## Theme acceptance (implementation)

See [#77](https://github.com/lucas-albers-lz4/fwlive/issues/77). Bootstrap + Material via `./scripts/qemu-theme-tint-smoke.sh`, plus chrome readability on dark variants.
