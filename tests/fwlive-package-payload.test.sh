#!/usr/bin/env bash
# Inspect a packaged data payload: shipped JS, LuCI ACL/menu files, and
# libexec layout/modes must survive either the ipk or apk packaging format.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG_DIR="$ROOT/openwrt-feed/luci-app-fwlive"
VERSION="$(sed -n 's/^PKG_VERSION:=//p' "$PKG_DIR/Makefile")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

package_format() {
	case "$1" in
		*.ipk) printf '%s' 'ipk' ;;
		*.apk) printf '%s' 'apk' ;;
		*) return 1 ;;
	esac
}

expected_package() {
	case "$1" in
		ipk) printf 'luci-app-fwlive_%s*.ipk' "$VERSION" ;;
		apk) printf 'luci-app-fwlive-%s*.apk' "$VERSION" ;;
		*) echo "unsupported package format: $1" >&2; return 1 ;;
	esac
}

REQUESTED_FORMAT="${FWLIVE_PACKAGE_FORMAT:-}"
PKG="${FWLIVE_PACKAGE:-${FWLIVE_IPK:-}}"
if [ -n "$PKG" ]; then
	[ -f "$PKG" ] || { echo "package not found: $PKG" >&2; exit 1; }
	FORMAT="$(package_format "$PKG")" || {
		echo "package must end in .ipk or .apk: $PKG" >&2
		exit 1
	}
	if [ -n "$REQUESTED_FORMAT" ] && [ "$REQUESTED_FORMAT" != "$FORMAT" ]; then
		echo "package format mismatch: expected $REQUESTED_FORMAT, got $FORMAT" >&2
		exit 1
	fi
	case "$FORMAT" in
		ipk)
			case "$(basename "$PKG")" in
				luci-app-fwlive_"$VERSION"*.ipk) ;;
				*) echo "ipk is not current version $VERSION: $PKG" >&2; exit 1 ;;
			esac
			;;
		apk)
			case "$(basename "$PKG")" in
				luci-app-fwlive-"$VERSION"*.apk) ;;
				*) echo "apk is not current version $VERSION: $PKG" >&2; exit 1 ;;
			esac
			;;
	esac
else
	FORMAT="$REQUESTED_FORMAT"
	if [ -z "$FORMAT" ]; then
		PATTERN_IPK="$(expected_package ipk)"
		PATTERN_APK="$(expected_package apk)"
		# Prefer the host-native ipk when both local artifact formats are
		# present; the ordinary host suite does not require an apk extractor.
		PKG="$(find "$ROOT/out" -type f -path '*/fwlive/*' -name "$PATTERN_IPK" -print 2>/dev/null |
			LC_ALL=C sort | tail -n 1 || true)"
		if [ -n "$PKG" ]; then
			FORMAT=ipk
		else
			PKG="$(find "$ROOT/out" -type f -path '*/fwlive/*' -name "$PATTERN_APK" -print 2>/dev/null |
				LC_ALL=C sort | tail -n 1 || true)"
			[ -z "$PKG" ] || FORMAT=apk
		fi
	else
		case "$FORMAT" in
			ipk | apk) ;;
			*) echo "unsupported package format: $FORMAT" >&2; exit 1 ;;
		esac
		PATTERN="$(expected_package "$FORMAT")"
		PKG="$(find "$ROOT/out" -type f -path '*/fwlive/*' -name "$PATTERN" -print 2>/dev/null |
			LC_ALL=C sort | tail -n 1 || true)"
	fi
fi

REQUIRE_PACKAGE="${FWLIVE_REQUIRE_PACKAGE:-${FWLIVE_REQUIRE_IPK:-0}}"
if [ -z "$PKG" ]; then
	if [ "$REQUIRE_PACKAGE" = 1 ]; then
		echo "no built current-version package found; set FWLIVE_PACKAGE or build the package first" >&2
		exit 1
	fi
	# The ordinary host suite has no SDK build. Create a package-shaped ipk
	# fixture from the shipped tree so the archive inspector still executes;
	# release/package jobs set FWLIVE_REQUIRE_PACKAGE=1 to require a real artifact.
	FORMAT=ipk
	PAYLOAD="$WORK/payload"
	mkdir -p "$PAYLOAD/www/luci-static/resources" "$PAYLOAD/www/luci-static/resources/view/status"
	cp -a "$PKG_DIR/root/usr" "$PAYLOAD/"
	cp -a "$PKG_DIR/htdocs/luci-static/resources/fwlive" \
		"$PAYLOAD/www/luci-static/resources/"
	cp "$PKG_DIR/htdocs/luci-static/resources/view/status/fwlive.js" \
		"$PAYLOAD/www/luci-static/resources/view/status/"
	tar -C "$PAYLOAD" -czf "$WORK/data.tar.gz" .
	tar -C "$WORK" -czf "$WORK/source-fixture.ipk" data.tar.gz
	PKG="$WORK/source-fixture.ipk"
	echo "fwlive package payload: inspecting source-shaped fixture (no current build present)"
else
	echo "fwlive package payload: inspecting $FORMAT package $PKG"
fi

PAYLOAD_DIR="${FWLIVE_PAYLOAD_DIR:-}"
if [ -n "$PAYLOAD_DIR" ]; then
	[ -d "$PAYLOAD_DIR" ] || { echo "payload directory not found: $PAYLOAD_DIR" >&2; exit 1; }
	EXTRACT="$PAYLOAD_DIR"
elif [ "$FORMAT" = apk ]; then
	if ! command -v apk >/dev/null 2>&1; then
		echo "apk package requires FWLIVE_PAYLOAD_DIR or the apk extractor" >&2
		exit 1
	fi
	EXTRACT="$WORK/extract"
	mkdir -p "$EXTRACT"
	(
		cd "$EXTRACT"
		apk --allow-untrusted extract "$PKG"
	)
else
	DATA="$WORK/data.tar.gz"
	if tar -xOf "$PKG" ./data.tar.gz >"$DATA" 2>/dev/null; then
		:
	elif tar -xOf "$PKG" data.tar.gz >"$DATA" 2>/dev/null; then
		:
	elif ar p "$PKG" data.tar.gz >"$DATA" 2>/dev/null; then
		:
	else
		echo "could not extract data.tar.gz from ipk: $PKG" >&2
		exit 1
	fi
	EXTRACT="$WORK/extract"
	mkdir -p "$EXTRACT"
	tar -xzf "$DATA" -C "$EXTRACT"
fi

MODULE_DIR="$PKG_DIR/htdocs/luci-static/resources/fwlive"
module_count=0
while IFS= read -r module; do
	base="$(basename "$module")"
	test -f "$EXTRACT/www/luci-static/resources/fwlive/$base" ||
		{ echo "missing packaged module: $base" >&2; exit 1; }
	module_count=$((module_count + 1))
done < <(
	cd "$MODULE_DIR"
	find . -type f -name '*.js' -print |
		sed 's#^\./##; /\//d' |
		LC_ALL=C sort
)
[ "$module_count" -eq 14 ] ||
	{ echo "expected 14 fwlive resource modules, found $module_count" >&2; exit 1; }
test -f "$EXTRACT/www/luci-static/resources/view/status/fwlive.js"

test -s "$EXTRACT/usr/share/rpcd/acl.d/luci-app-fwlive.json"
test -s "$EXTRACT/usr/share/luci/menu.d/luci-app-fwlive.json"
node - "$PKG_DIR/root/usr/share/rpcd/acl.d/luci-app-fwlive.json" \
	"$EXTRACT/usr/share/rpcd/acl.d/luci-app-fwlive.json" <<'NODE'
const fs = require('node:fs');
const source = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const packaged = JSON.parse(fs.readFileSync(process.argv[3], 'utf8'));
if (!packaged['luci-app-fwlive'] || !packaged['luci-app-fwlive'].read)
	process.exit(1);
if (JSON.stringify(source) !== JSON.stringify(packaged))
	throw new Error('packaged ACL differs from the source ACL');
const read = packaged['luci-app-fwlive'].read.ubus || {};
if (Object.prototype.hasOwnProperty.call(read, 'log'))
	throw new Error('packaged ACL grants ubus log.*');
NODE

while IFS= read -r rel; do
	test -f "$EXTRACT/usr/libexec/$rel" ||
		{ echo "missing packaged libexec file: $rel" >&2; exit 1; }
	case "$rel" in
		fwlive-log-filter.sh|fwlive-logging.sh|rpcd/fwlive)
			test -x "$EXTRACT/usr/libexec/$rel" ||
				{ echo "packaged executable lost mode: $rel" >&2; exit 1; }
			;;
		*)
			test ! -x "$EXTRACT/usr/libexec/$rel" ||
				{ echo "sourced helper unexpectedly executable: $rel" >&2; exit 1; }
			;;
	esac
done < <(
	cd "$PKG_DIR/root/usr/libexec"
	find . -type f -print |
		sed 's#^\./##' |
		LC_ALL=C sort
)

echo "fwlive $FORMAT package payload test passed ($module_count modules)"
