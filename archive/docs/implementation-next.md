# Implementation checklist

**Status:** Applied during plan execution (2026-03-29).

| Item | Status |
|------|--------|
| [`docs/dev-environment.md`](dev-environment.md) | Done |
| [`README.md`](../README.md) rewrite | Done |
| [`docker-compose.yml`](../docker-compose.yml) SDK matrix (`sdk` + `sdk-official`) | Done |
| [`scripts/docker-sdk.sh`](../scripts/docker-sdk.sh) + `docker-sdk-official-*.sh` | Done |
| [`docs/sdk-build-matrix.md`](sdk-build-matrix.md) | Done |
| [`scripts/run-openwrt-armsr-armv8-qemu.sh`](../scripts/run-openwrt-armsr-armv8-qemu.sh) Linux-only, single NIC + hostfwd (matches x86) | Done |
| [`scripts/legacy/run-openwrt-armsr-armv8-qemu-macos.sh`](../scripts/legacy/run-openwrt-armsr-armv8-qemu-macos.sh) | Done |
| [`lab/compose.yml`](../lab/compose.yml) armsr **8080:80** | Done |
| [`docs/fwlive-nft-logging.md`](fwlive-nft-logging.md) | Done |
| Docs: minimal-build-sdk, openwrt-feed, armvirt, acceptance | Done |

**Your next commands:**

```sh
./scripts/docker-sdk.sh list
./scripts/docker-sdk.sh build                    # armsr-armv8 + snapshot
./scripts/docker-sdk.sh build-all              # optional: all version × target cells
./scripts/run-openwrt-armsr-armv8-qemu.sh
./scripts/agent-build-and-deploy.sh --legacy-hostfwd --ipk out/aarch64_generic/snapshot/fwlive/luci-app-fwlive_*.ipk
```

**Still manual (you):** MVP sign-off on live guest per [`fwlive-acceptance.md`](fwlive-acceptance.md) and [`opnsense-liveview-parity.md`](opnsense-liveview-parity.md).
