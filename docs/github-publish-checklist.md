# GitHub upstream checklist

Use this when you turn this tree into the **canonical upstream** repo.

## Repo contents (recommended)

- **Include:** `openwrt-feed/`, `docs/`, `tests/`, `lab/`, `scripts/`, `README.md`, `feeds.conf.example`, `.gitignore`
- **Exclude:** Do not commit full `openwrt/`, `luci/`, `core/`, `firewall4/` clones (see root `.gitignore`). Document “clone upstream for reference” in README instead.

## After publish

- In `feeds.conf.example` and `openwrt-feed/README.md`, add an optional **`src-git`** line:

  `src-git fwview https://github.com/YOU/fwview.git^openwrt-feed`

  (Adjust branch/subdir if the feed lives in a subfolder of the repo; `src-git` pulls a repo root—if the feed is at repo root, symlink or structure the repo so `openwrt-feed` is the feed root, **or** publish a tiny repo that only contains `luci-app-fwlive`.)

**Note:** `src-git` points at a **git repo**; OpenWrt expects package directories at the **root** of that checkout. This repo’s feed layout is **`openwrt-feed/`** as the feed root, so either:

- Publish with feed root = repo root by moving packages up, **or**
- Keep `src-link` / tarball workflow, **or**
- Use `src-git` to a branch where the feed root is the repo root.

## No i18n for now

- Skip `po/` and `luci-i18n-*` until you explicitly want translations.
