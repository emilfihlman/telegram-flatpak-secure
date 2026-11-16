#!/usr/bin/env bash
# Run on a worker against a private, hardware-free Pulse fixture. Its output
# sink is telegram-test-output; its live synthetic input is telegram-test-input
# (PulseAudio sine source) or telegram-test-input.monitor (PipeWire null sink).
# Set TG_TEST_RUNTIME, TG_TEST_PULSE_SOCKET and TG_TEST_SOURCE to that fixture.
set -euo pipefail
umask 077

test_dir=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$test_dir/../telegram-audio.bash"
TG_RUNTIME=${TG_TEST_RUNTIME:?Set the private synthetic fixture runtime}
TG_PULSE_SOCKET=${TG_TEST_PULSE_SOCKET:?Set its private Pulse socket}
test_source=${TG_TEST_SOURCE:?Set its synthetic input source}
[[ $test_source == telegram-test-input || $test_source == telegram-test-input.monitor ]]
[[ -d $TG_RUNTIME && -S $TG_PULSE_SOCKET ]]

# Refuse a normal desktop's device inventory before recording or playing data.
# Only explicitly named synthetic fixture nodes are permitted here.
for kind in sinks sources; do
	inventory=$(pactl --server="unix:$TG_PULSE_SOCKET" list short "$kind")
	while IFS=$'\t' read -r _index name _rest; do
		[[ -z $name || $name == telegram-test-* ]] || {
			printf 'Use a private synthetic audio fixture, without hardware devices.\n' >&2
			exit 1
		}
	done <<< "$inventory"
done

scratch=$(mktemp -d "$TG_RUNTIME/telegram-audio-test.XXXXXX")
recorder=
cleanup() {
	if [[ -n $recorder ]]; then kill "$recorder" 2>/dev/null || true; wait "$recorder" 2>/dev/null || true; fi
	tg_audio_stop
	rm -rf -- "$scratch"
}
trap cleanup EXIT

capture() {
	local socket=$1 source=$2 output=$3 status=0
	timeout --signal=INT 0.7 parec --latency-msec=30 --server="unix:$socket" \
		--device="$source" --file-format=wav "$output" 2>"$scratch/record.log" || status=$?
	[[ $status == 0 || $status == 124 ]]
}

rms() { sox "$1" -n stat 2>&1 | awk '/RMS.*amplitude:/ { print $3 }'; }
capture "$TG_PULSE_SOCKET" "$test_source" "$scratch/host-input.wav"
host_rms=$(rms "$scratch/host-input.wav")
awk -v value="$host_rms" 'BEGIN { exit !(value>0.05) }'

tg_audio_start
broker_pid=$TG_AUDIO_PID
broker_dir=$TG_AUDIO_DIR
status=0
timeout --signal=INT 1 parec --latency-msec=30 --server="unix:$TG_AUDIO_SOCKET" \
	--device="$test_source" --file-format=wav "$scratch/forbidden.wav" 2>"$scratch/denied.log" || status=$?
[[ $status != 0 && $status != 124 ]]
if [[ $TG_AUDIO_PROVIDER == pulseaudio ]]; then
	capture "$TG_AUDIO_SOCKET" telegram-silence "$scratch/silence.wav"
	[[ $(rms "$scratch/silence.wav") == 0.000000 ]]
else
	grep -q 'Access denied' "$scratch/denied.log"
fi
if pactl --server="unix:$TG_AUDIO_SOCKET" load-module module-null-source >"$scratch/module.log" 2>&1; then
	printf 'Private audio server allowed client module loading.\n' >&2
	exit 1
fi

sox -n -r 48000 -c 2 -b 16 "$scratch/signal.wav" synth 0.3 sine 1000 gain -12
timeout --signal=INT 1.5 parec --latency-msec=30 --server="unix:$TG_PULSE_SOCKET" \
	--device=telegram-test-output.monitor --file-format=wav "$scratch/playback.wav" 2>"$scratch/monitor.log" &
recorder=$!
sleep 0.1
paplay --server="unix:$TG_AUDIO_SOCKET" "$scratch/signal.wav"
wait "$recorder" || [[ $? == 124 ]]
recorder=
playback_rms=$(rms "$scratch/playback.wav")
awk -v value="$playback_rms" 'BEGIN { exit !(value>0.005) }'
tg_audio_stop
[[ ! -e $broker_dir ]] && ! kill -0 "$broker_pid" 2>/dev/null
printf 'provider=%s host-input-rms=%s playback-rms=%s microphone-isolated=yes module-loading-denied=yes cleanup=yes\n' \
	"$TG_AUDIO_PROVIDER" "$host_rms" "$playback_rms"
