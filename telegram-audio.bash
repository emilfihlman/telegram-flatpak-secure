#!/usr/bin/env bash
# Each sandbox receives a private PipeWire/Pulse endpoint with approved inputs.

tg_audio_close_fds() {
	local descriptor
	for descriptor in /proc/self/fd/*; do
		descriptor=${descriptor##*/}
		[[ $descriptor =~ ^[0-9]+$ ]] || continue
		(( descriptor > 2 )) || continue
		[[ $descriptor != "${1:-}" ]] || continue
		exec {descriptor}>&-
	done
}

tg_audio_supported() {
	local command sibling=${BASH_SOURCE[0]%/*}
	TG_AUDIO_PROVIDER=pipewire
	for command in bwrap pipewire wireplumber pactl parec timeout; do
		command -v "$command" >/dev/null || return 1
	done
	for command in telegram-audio-broker.bash telegram-microphones.bash telegram-consent.bash; do
		[[ -x $sibling/$command ]] || return 1
	done
}

tg_audio_stop() {
	if [[ -n ${TG_AUDIO_PID:-} ]]; then
		kill -TERM -- "$TG_AUDIO_PID" 2>/dev/null || true
		wait "$TG_AUDIO_PID" 2>/dev/null || true
		TG_AUDIO_PID=
	fi
	if [[ -n ${TG_AUDIO_DIR:-} ]]; then
		rm -rf -- "$TG_AUDIO_DIR"
		TG_AUDIO_DIR=
	fi
	TG_AUDIO_SOCKET=
}

tg_audio_start() {
	local sibling=${BASH_SOURCE[0]%/*} notification_fd input_fd socket directory suffix status
	TG_AUDIO_PID=
	TG_AUDIO_DIR=
	TG_AUDIO_SOCKET=
	tg_audio_supported || {
		printf 'The private audio broker is unavailable. Run ./telegram-setup.bash.\n' >&2
		return 1
	}
	[[ ${TG_RUNTIME:-} == /* && -d $TG_RUNTIME && -O $TG_RUNTIME && ${TG_HOME:-} == /* ]] || return 1
	[[ ${TG_NATIVE_CONSENT:-} =~ ^(yes|no)\ (yes|no)$ ]] || {
		printf 'Native microphone/camera consent was not supplied to the audio broker.\n' >&2
		return 1
	}
	# Flatpak invokes its hook with an empty environment. Reconstruct only the
	# trusted desktop paths; no app-controlled audio/config environment survives.
	coproc TG_AUDIO_READY {
		tg_audio_close_fds
		exec /usr/bin/bwrap --unshare-user --die-with-parent --bind / / -- \
			env -i PATH=/usr/bin:/bin "HOME=$TG_HOME" "XDG_RUNTIME_DIR=$TG_RUNTIME" \
			"DBUS_SESSION_BUS_ADDRESS=unix:path=$TG_RUNTIME/bus" \
			"TELEGRAM_EXPECTED_CONSENT=$TG_NATIVE_CONSENT" \
			/usr/bin/bash "$sibling/telegram-audio-broker.bash" --serve
	}
	TG_AUDIO_PID=${TG_AUDIO_READY_PID:-}
	notification_fd=${TG_AUDIO_READY[0]:-}
	input_fd=${TG_AUDIO_READY[1]:-}
	if [[ -z $TG_AUDIO_PID || -z $notification_fd || -z $input_fd ]]; then
		tg_audio_stop
		return 1
	fi
	exec {input_fd}>&-
	if IFS= read -r -t 60 -u "$notification_fd" socket; then
		status=0
	else
		status=$?
	fi
	exec {notification_fd}<&-
	if (( status != 0 )); then
		tg_audio_stop
		printf 'The private audio broker did not become ready.\n' >&2
		return 1
	fi
	directory=${socket%/pulse/native}
	suffix=${directory#"$TG_RUNTIME/telegram-audio/instance."}
	if [[ ! $suffix =~ ^[A-Za-z0-9]{6}$ || $socket != "$TG_RUNTIME/telegram-audio/instance.$suffix/pulse/native" ||
		! -d $directory || -L $directory || ! -O $directory || $(stat -Lc '%a' -- "$directory") != 700 ||
		! -S $socket || -L $socket || ! -O $socket ]]; then
		tg_audio_stop
		printf 'The private audio broker returned an invalid endpoint.\n' >&2
		return 1
	fi
	TG_AUDIO_DIR=$directory
	TG_AUDIO_SOCKET=$socket
}

# Bubblewrap keeps a pipe open for the whole sandbox, including a Telegram
# relaunch in the same PID namespace. Bridge its existing native sync handle
# so Flatpak's own D-Bus proxy lifetime remains unchanged.
tg_audio_sandbox() {
	local native_sync_fd=${1:-} lifetime_pid='' finished status=0
	tg_audio_close_fds "$native_sync_fd"
	cleanup() {
		if [[ -n $native_sync_fd ]]; then exec {native_sync_fd}>&-; native_sync_fd=; fi
		if [[ -n $lifetime_pid ]]; then
			kill -TERM -- "$lifetime_pid" 2>/dev/null || true
			wait "$lifetime_pid" 2>/dev/null || true
		fi
		tg_audio_stop
	}
	trap cleanup EXIT
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 141' PIPE
	tg_audio_start || exit 1
	printf '%s\n' "$TG_AUDIO_SOCKET"
	exec 1>&-
	(tg_audio_close_fds; IFS= read -r _ || true) <&0 &
	lifetime_pid=$!
	wait -n -p finished "$TG_AUDIO_PID" "$lifetime_pid" || status=$?
	if [[ $finished == "$TG_AUDIO_PID" ]]; then
		TG_AUDIO_PID=
		printf 'Error: Telegram audio stopped unexpectedly.\n' >&2
		exit 1
	fi
	lifetime_pid=
	exit "$status"
}
