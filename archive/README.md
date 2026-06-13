# Archive (unmaintained / legacy)

Items kept for reference. **Do not use for production builds** — use [`scripts/docker-sdk.sh`](../scripts/docker-sdk.sh) and Linux QEMU runners instead.

| Path | Was | Replacement |
|------|-----|-------------|
| `scripts/legacy/` | macOS vmnet QEMU (hvf) | Linux: `scripts/run-openwrt-armsr-armv8-qemu.sh` |
| `scripts/docker-sdk-{import-tar,setup-feeds,make}.sh` | fwlive-built SDK volume | `scripts/docker-sdk.sh` + `ghcr.io/openwrt/sdk` |
| `scripts/run-openwrt-rootfs-x86-docker.sh` | Deprecated wrapper | `scripts/run-openwrt-x86-experiment.sh` |
| `scripts/docker-compose.bind.yml` | macOS case-sensitive bind mount | Linux native or Docker volume SDK |
| `macos/set-build-env.sh` | Homebrew GNU PATH | Build on Linux x86_64 (VM/CI) |
| `macos/install-depends.sh` | `brew install` one-liner | [`docs/dev-environment.md`](../docs/dev-environment.md) |
| `docs/implementation-next.md` | One-time 2026-03 checklist | Done — see [`docs/ROADMAP.md`](../docs/ROADMAP.md) |

**macOS development:** edit JS/docs locally; run `./scripts/fwlive-test.sh` with Node. SDK builds and QEMU labs require **Linux x86_64**.
