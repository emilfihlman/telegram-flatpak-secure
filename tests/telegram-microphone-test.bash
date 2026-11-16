#!/usr/bin/env bash
# Run only against a private hardware-free fixture: true sources mic-a (440 Hz)
# and mic-b (880 Hz), plus a null sink test-output and its monitor.
# Set TG_TEST_RUNTIME and TG_TEST_PULSE_SOCKET to that fixture on a worker.
set -euo pipefail
umask 077

test_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
programs=${TG_TEST_PROGRAMS:-$test_dir/..}
source "$programs/telegram-media.bash"
source "$programs/telegram-audio.bash"
TG_RUNTIME=${TG_TEST_RUNTIME:?Set the private synthetic fixture runtime}
TG_PULSE_SOCKET=${TG_TEST_PULSE_SOCKET:?Set its private Pulse socket}
[[ -d $TG_RUNTIME && -S $TG_PULSE_SOCKET ]]
host() { pactl --server="unix:$TG_PULSE_SOCKET" "$@"; }
broker() { pactl --server="unix:$TG_AUDIO_SOCKET" "$@"; }
wait_source() {
	local attempt
	for ((attempt=0; attempt<50; attempt++)); do
		if broker list short sources | awk -F '\t' -v name="$1" '$2 == name { found = 1 } END { exit !found }'; then return 0; fi
		sleep 0.02
	done
	return 1
}

# Reject ordinary desktop inventories before any audio is recorded or played.
for kind in sinks sources; do
	inventory=$(host list short "$kind")
	while IFS=$'\t' read -r _index name _rest; do
		case $name in
			''|mic-a|mic-b|test-output|test-output.monitor) ;;
			*) printf 'Use the private synthetic microphone fixture, without hardware.\n' >&2; exit 1 ;;
		esac
	done <<< "$inventory"
done
for source in mic-a mic-b; do
	host list short sources | awk -F '\t' -v name="$source" '$2 == name { found = 1 } END { exit !found }'
done

scratch=$(mktemp -d "$TG_RUNTIME/telegram-microphone-test.XXXXXX")
recorder=
mic_a_removed=no
mic_a_module=
mic_a_arguments=()
original_default=$(host get-default-source)
cleanup() {
	if [[ -n $recorder ]]; then kill "$recorder" 2>/dev/null || true; wait "$recorder" 2>/dev/null || true; fi
	tg_audio_stop
	if [[ $mic_a_removed == yes ]]; then host load-module "$mic_a_module" "${mic_a_arguments[@]}" > /dev/null || true; fi
	host set-default-source "$original_default" 2>/dev/null || true
	rm -rf -- "$scratch"
}
trap cleanup EXIT

capture() {
	# The synthetic generator can deliver a one-second buffered block.
	local socket=$1 source=$2 output=$3 duration=${4:-1.2}
	capture_status=0
	timeout --signal=INT "$duration" parec --latency-msec=20 --server="unix:$socket" \
		--device="$source" --file-format=wav "$output" 2> "$scratch/record.log" || capture_status=$?
}
capture_ok() {
	capture "$@"
	[[ $capture_status == 0 || $capture_status == 124 ]]
}
rms() {
	local statistics value
	statistics=$(sox "$1" -n "${@:2}" stat 2>&1) || return 1
	value=$(awk '/RMS.*amplitude:/ { print $3 }' <<< "$statistics")
	# SoX reports -nan for an empty WAV left by a denied/disconnected stream.
	[[ $value =~ ^[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?$ ]] || return 1
	printf '%s\n' "$value"
}
assert_not_b() {
	local value
	value=$(rms "$1" sinc 800-960) || return 0
	awk -v value="$value" -v baseline="$host_b_band" 'BEGIN { exit !(value < baseline * 0.03) }'
}
assert_a() {
	local value
	value=$(rms "$1" sinc 380-500) || return 1
	if ! awk -v value="$value" -v baseline="$host_a_band" 'BEGIN { exit !(value > baseline * 0.4) }'; then
		printf 'Expected mic-a: a-band=%s b-band=%s overall=%s\n' "$value" "$(rms "$1" sinc 800-960)" "$(rms "$1")" >&2
		return 1
	fi
	assert_not_b "$1"
}
assert_idle() {
	local attempt outputs
	for ((attempt=0; attempt<30; attempt++)); do
		outputs=$(host list source-outputs)
		if awk -v broker_pid="$TG_AUDIO_PID" '
			function check() { if (output && pid == broker_pid && corked != "yes") active = 1 }
			/^Source Output #[0-9]+$/ { check(); output = 1; corked = ""; pid = "" }
			/^[\t ]*Corked: / { corked = $2 }
			/^[\t ]*application.process.id = / { pid = $3; gsub(/"/, "", pid) }
			END { check(); exit active }
		' <<< "$outputs"; then return 0; fi
		sleep 0.1
	done
	printf 'Host recording remained active after the private recorder ended:\n%s\n' "$outputs" >&2
	return 1
}

capture_ok "$TG_PULSE_SOCKET" mic-a "$scratch/host-a.wav"
capture_ok "$TG_PULSE_SOCKET" mic-b "$scratch/host-b.wav"
host_a_band=$(rms "$scratch/host-a.wav" sinc 380-500)
host_b_band=$(rms "$scratch/host-b.wav" sinc 800-960)
awk -v a="$host_a_band" -v b="$host_b_band" 'BEGIN { exit !(a > 0.05 && b > 0.05) }'
assert_not_b "$scratch/host-a.wav"
denied_index=$(host list short sources | awk -F '\t' '$2 == "mic-b" { print $1 }')
[[ $denied_index =~ ^[0-9]+$ ]]

TG_MICROPHONE_MODE=selected
TG_MICROPHONE_IDS=(mic-a)
tg_audio_start
[[ $TG_AUDIO_PROVIDER == pulseaudio ]]
wait_source mic-a
sources=$(broker list short sources)
while IFS=$'\t' read -r _index name _rest; do
	case $name in mic-a|telegram-silence|telegram-playback.monitor) ;; *) exit 1 ;; esac
done <<< "$sources"
awk -F '\t' '$2 == "mic-a" { found = 1 } END { exit !found }' <<< "$sources"
assert_idle
capture_ok "$TG_AUDIO_SOCKET" mic-a "$scratch/approved.wav"
assert_a "$scratch/approved.wav"
assert_idle

# Source numbers are private-server indexes. A host number may name an allowed
# local source or be absent; neither case may expose the denied host input.
capture "$TG_AUDIO_SOCKET" mic-b "$scratch/denied-name.wav"
[[ $capture_status != 0 && $capture_status != 124 ]]
capture "$TG_AUDIO_SOCKET" "$denied_index" "$scratch/denied-index.wav"
assert_not_b "$scratch/denied-index.wav"
if broker set-default-source mic-b > "$scratch/default-denied.log" 2>&1; then exit 1; fi
host set-default-source mic-b
capture_ok "$TG_AUDIO_SOCKET" @DEFAULT_SOURCE@ "$scratch/default.wav"
assert_a "$scratch/default.wav"

timeout --signal=INT 2 parec --latency-msec=20 --server="unix:$TG_AUDIO_SOCKET" \
	--device=mic-a --file-format=wav "$scratch/moved.wav" 2> "$scratch/move-record.log" &
recorder=$!
stream=
for ((attempt=0; attempt<20; attempt++)); do
	stream=$(broker list short source-outputs | awk -F '\t' 'NR == 1 { print $1 }')
	[[ ! $stream =~ ^[0-9]+$ ]] || break
	sleep 0.05
done
[[ $stream =~ ^[0-9]+$ ]]
if broker move-source-output "$stream" mic-b > "$scratch/move-denied.log" 2>&1; then exit 1; fi
broker move-source-output "$stream" "$denied_index" > "$scratch/move-index.log" 2>&1 || true
wait "$recorder" || [[ $? == 124 ]]
recorder=
assert_not_b "$scratch/moved.wav"
assert_idle
if broker load-module module-null-source > "$scratch/module-denied.log" 2>&1; then exit 1; fi

# Both fixtures expose an unloadable source module with an explicit mic-a
# target: a sine generator on PulseAudio, or its source tunnel on PipeWire.
hotplug=not-exercised
owner=$(host list sources | awk '
	/^Source #[0-9]+$/ { name = ""; owner = "" }
	/^[\t ]*Name: / { name = $2 }
	/^[\t ]*Owner Module: / { owner = $3; if (name == "mic-a") print owner }
')
module_row=$(host list short modules | awk -F '\t' -v owner="$owner" '$1 == owner { print }')
IFS=$'\t' read -r _module mic_a_module arguments _rest <<< "$module_row"
if [[ $mic_a_module == module-sine-source || $mic_a_module == module-tunnel-source ]]; then
	if [[ $mic_a_module == module-tunnel-source ]]; then
		[[ " $arguments " == *' source=mic-a '* ]]
	fi
	read -r -a mic_a_arguments <<< "$arguments"
	host unload-module "$owner"
	mic_a_removed=yes
	capture "$TG_AUDIO_SOCKET" @DEFAULT_SOURCE@ "$scratch/removed.wav"
	assert_not_b "$scratch/removed.wav"
	broker info > /dev/null
	host load-module "$mic_a_module" "${mic_a_arguments[@]}" > /dev/null
	mic_a_removed=no
	recovered=no
	for ((attempt=0; attempt<10; attempt++)); do
		capture "$TG_AUDIO_SOCKET" mic-a "$scratch/restored.wav"
		if assert_a "$scratch/restored.wav"; then recovered=yes; break; fi
		sleep 0.3
	done
	[[ $recovered == yes ]]
	assert_idle
	hotplug=passed
fi
tg_audio_stop

# An absent saved source must yield silence rather than selecting the desktop
# default (still mic-b). Playback must remain available in this state.
TG_MICROPHONE_IDS=(absent-microphone)
tg_audio_start
capture_ok "$TG_AUDIO_SOCKET" @DEFAULT_SOURCE@ "$scratch/absent.wav"
[[ $(rms "$scratch/absent.wav") == 0.000000 ]]
for source in mic-a mic-b absent-microphone; do
	capture "$TG_AUDIO_SOCKET" "$source" "$scratch/absent-$source.wav"
	[[ $capture_status != 0 && $capture_status != 124 ]]
done
sox -n -r 48000 -c 2 -b 16 "$scratch/signal.wav" synth 0.3 sine 1000 gain -12
timeout --signal=INT 1.5 parec --latency-msec=20 --server="unix:$TG_PULSE_SOCKET" \
	--device=test-output.monitor --file-format=wav "$scratch/playback.wav" 2> "$scratch/playback.log" &
recorder=$!
sleep 0.1
paplay --server="unix:$TG_AUDIO_SOCKET" "$scratch/signal.wav"
wait "$recorder" || [[ $? == 124 ]]
recorder=
playback_rms=$(rms "$scratch/playback.wav")
awk -v value="$playback_rms" 'BEGIN { exit !(value > 0.005) }'
assert_idle
tg_audio_stop

TG_MICROPHONE_IDS=(mic-a mic-b)
tg_audio_start
wait_source mic-a
wait_source mic-b
capture_ok "$TG_AUDIO_SOCKET" mic-a "$scratch/multiple-a.wav"
assert_a "$scratch/multiple-a.wav"
capture_ok "$TG_AUDIO_SOCKET" mic-b "$scratch/multiple-b.wav"
allowed_b=$(rms "$scratch/multiple-b.wav" sinc 800-960)
awk -v value="$allowed_b" -v baseline="$host_b_band" 'BEGIN { exit !(value > baseline * 0.4) }'
tg_audio_stop
printf 'selected=mic-a denied=mic-b multiple=passed name-index-default-move=isolated module-loading=denied capture-idle=yes hotplug=%s absent=silence playback-rms=%s\n' "$hotplug" "$playback_rms"
