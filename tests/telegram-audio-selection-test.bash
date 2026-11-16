#!/usr/bin/env bash
# Exercise the consent/selection intersection with a synthetic source inventory.
set -euo pipefail
umask 077

test_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$test_dir/../telegram-media.bash"
source "$test_dir/../telegram-microphones.bash"
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
TG_PROGRAMS=$scratch
TG_PULSE_SOCKET=$scratch/unused-test-socket
cat > "$scratch/telegram-consent.bash" <<'CONSENT'
#!/usr/bin/env bash
[[ $1 == snapshot ]]
[[ ${TG_TEST_CONSENT:-} != error ]] || exit 1
printf '%s\n' "$TG_TEST_CONSENT"
CONSENT
chmod 755 "$scratch/telegram-consent.bash"
cat > "$scratch/sources" <<'SOURCES'
Source #1
	Name: mic-a
	Description: Test A
	Monitor of Sink: n/a
Source #2
	Name: mic-b
	Description: Test B
	Monitor of Sink: n/a
Source #3
	Name: disguised-host-monitor
	Description: Playback monitor with a nonstandard name
	Monitor of Sink: 9
Source #4
	Name: 123mic
	Description: Numeric alias
	Monitor of Sink: n/a
Source #5
	Name: unknown-kind
	Description: Missing authoritative source kind
Source #6
	Name: ordinary.monitor
	Description: Ambiguous monitor suffix
	Monitor of Sink: n/a
Source #7
	Name: untrusted"; value
	Description: Configuration injection
	Monitor of Sink: n/a
SOURCES
tg_microphones_host_server() { printf 'unix:%s\n' "$TG_PULSE_SOCKET"; }
tg_microphone_sources() {
	: > "$scratch/enumerated"
	cat -- "$scratch/sources"
}
resolve() {
	rm -f -- "$scratch/enumerated"
	tg_microphones_resolve > "$scratch/resolved" || return 1
	mapfile -d '' -t resolved < "$scratch/resolved"
}

export TG_TEST_CONSENT='no no'
TG_MICROPHONE_MODE=all
TG_MICROPHONE_IDS=()
resolve
[[ ${#resolved[@]} == 0 && ! -e $scratch/enumerated ]]
TG_TEST_CONSENT='no yes'
resolve
[[ ${#resolved[@]} == 0 && ! -e $scratch/enumerated ]]
TG_TEST_CONSENT='yes yes'
TG_MICROPHONE_MODE=none
resolve
[[ ${#resolved[@]} == 0 && ! -e $scratch/enumerated ]]
TG_MICROPHONE_MODE=all
resolve
[[ ${resolved[*]} == 'mic-a mic-b' ]]
TG_MICROPHONE_MODE=selected
TG_MICROPHONE_IDS=(mic-a)
resolve
[[ ${resolved[*]} == mic-a ]]
TG_MICROPHONE_IDS=(disconnected)
resolve
[[ ${#resolved[@]} == 0 ]]
TG_MICROPHONE_IDS=(mic-b mic-a)
resolve
[[ ${resolved[*]} == 'mic-b mic-a' ]]
TG_TEST_CONSENT='ask yes'
if resolve; then exit 1; fi
TG_TEST_CONSENT=error
if resolve; then exit 1; fi
printf 'PASS: native consent intersects selected/all/none; monitors, aliases, invalid names and absent inputs never expand access.\n'
