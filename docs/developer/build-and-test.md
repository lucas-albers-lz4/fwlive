# Build and test

## SDK builds

```sh
./scripts/docker-sdk.sh list
./scripts/docker-sdk.sh build --target armsr-armv8 --version 24.10
./scripts/docker-sdk.sh build --target x86-64 --version 24.10
./scripts/docker-sdk.sh build-all          # all version × target cells
```

Artifacts: `out/<arch>/<version>/fwlive/luci-app-fwlive*.{ipk,apk}`

Matrix reference: [`../sdk-build-matrix.md`](../sdk-build-matrix.md)  
Native SDK (no Docker): [`../minimal-build-sdk.md`](../minimal-build-sdk.md)

## Parser tests (fast, no QEMU)

```sh
./scripts/fwlive-test.sh
./scripts/validate-baseline.sh
```

Covers parser sync (`core/` vs LuCI `log.js`), schema, filters, CLI pipeline.

## QEMU smoke (guest running)

```sh
./scripts/qemu-wait-guest.sh
./scripts/qemu-install-fwlive.sh
./scripts/qemu-smoke-fwlive.sh
```

Checks: ubus, rpcd rules, LuCI HTTP, firewall log pipeline.

## Version validation (full cell)

One version + architecture:

```sh
./scripts/validate-openwrt.sh --version 24.10
./scripts/validate-openwrt.sh --version 23.05 --qemu-target x86 --skip-build
```

All smokeable x86 versions:

```sh
./scripts/validate-openwrt-all.sh smoke-x86 --skip-build
```

Details: [`../validation-matrix.md`](../validation-matrix.md)

## Acceptance criteria

Functional, performance, and sign-off tables: [`../fwlive-acceptance.md`](../fwlive-acceptance.md).

## CI-friendly sequence

```sh
./scripts/validate-baseline.sh
./scripts/validate-openwrt-all.sh build
./scripts/validate-openwrt-all.sh smoke-x86 --skip-build
```

`smoke-x86` skips **snapshot** (minimal image, no LuCI).
