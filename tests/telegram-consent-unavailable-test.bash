#!/usr/bin/env bash
# A real native-store failure must prevent the managed command from starting.
# Uses private directories and an unreachable session bus; no desktop changes.
set -euo pipefail
umask 077
for command in flatpak gsettings busctl timeout awk; do
	command -v "$command" >/dev/null || {
		printf 'UNAVAILABLE: required native consent tool is missing: %s\n' "$command" >&2
		exit 77
	}
done
telegram_test_source=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
telegram_test_work=$(mktemp -d "${TMPDIR:-/tmp}/telegram-consent-failure.XXXXXX")
trap 'rm -rf -- "$telegram_test_work"' EXIT
mkdir -- "$telegram_test_work/home" "$telegram_test_work/run" "$telegram_test_work/data" \
	"$telegram_test_work/config" "$telegram_test_work/state" "$telegram_test_work/cache"

if timeout 15 env -u GSETTINGS_SCHEMA_DIR -u GSETTINGS_BACKEND -u DCONF_PROFILE \
	-u DBUS_STARTER_ADDRESS -u DBUS_STARTER_BUS_TYPE \
	HOME="$telegram_test_work/home" XDG_RUNTIME_DIR="$telegram_test_work/run" \
	XDG_CONFIG_HOME="$telegram_test_work/config" XDG_DATA_HOME="$telegram_test_work/data" \
	XDG_STATE_HOME="$telegram_test_work/state" XDG_CACHE_HOME="$telegram_test_work/cache" \
	FLATPAK_USER_DIR="$telegram_test_work/flatpak" \
	DBUS_SESSION_BUS_ADDRESS="unix:path=$telegram_test_work/no-such-bus" \
	bash "$telegram_test_source/telegram-consent.bash" --run 'no no' -- \
	sh -c 'touch "$1"' test "$telegram_test_work/command-ran" \
	> "$telegram_test_work/stdout" 2> "$telegram_test_work/stderr"; then
	printf '%s\n' 'FAIL: an unavailable native permission store was accepted.' >&2
	exit 1
else
	telegram_test_status=$?
fi

[[ $telegram_test_status != 124 && $telegram_test_status != 137 ]] || {
	printf '%s\n' 'FAIL: native consent startup did not fail within its time limit.' >&2
	exit 1
}
[[ ! -e $telegram_test_work/command-ran ]] || {
	printf '%s\n' 'FAIL: the managed command started without native consent monitoring.' >&2
	exit 1
}
grep -Fq 'Cannot read the native microphone/camera permission store.' "$telegram_test_work/stderr" || {
	cat "$telegram_test_work/stderr" >&2
	printf '%s\n' 'FAIL: the test did not reach the actual native permission-store check.' >&2
	exit 1
}
printf '%s\n' 'PASS: unavailable native consent prevents the managed command from starting.'
