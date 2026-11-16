#!/usr/bin/env bash
# A private native audio server exposes approved inputs and retains playback.

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
	local module modules private=${BASH_SOURCE[0]%/*}/pulseaudio
	TG_AUDIO_BINARY=
	TG_AUDIO_PULSE_ARGS=()
	TG_AUDIO_PRIVATE=
	command -v setpriv >/dev/null && command -v setsid >/dev/null || return 1
	if command -v pulseaudio >/dev/null; then
		TG_AUDIO_BINARY=$(command -v pulseaudio)
	elif [[ ${TG_MICROPHONE_MODE:-none} == selected && -x $private/bin/pulseaudio ]]; then
		TG_AUDIO_BINARY=$private/bin/pulseaudio
		TG_AUDIO_PRIVATE=$private
		TG_AUDIO_PULSE_ARGS=("--dl-search-path=$private/modules")
	fi
	if [[ -n $TG_AUDIO_BINARY ]]; then
		if [[ -n $TG_AUDIO_PRIVATE ]]; then
			modules=$(LD_BIND_NOW=1 LD_LIBRARY_PATH=$private/lib "$TG_AUDIO_BINARY" "${TG_AUDIO_PULSE_ARGS[@]}" --dump-modules) || return 1
		else
			modules=$("$TG_AUDIO_BINARY" --dump-modules) || return 1
		fi
		for module in module-native-protocol-unix module-tunnel-sink-new module-null-source module-cli module-suspend-on-idle module-switch-on-connect; do
			[[ $modules =~ (^|$'\n')${module}[[:space:]] ]] || return 1
		done
		TG_AUDIO_PROVIDER=pulseaudio
		if [[ ${TG_MICROPHONE_MODE:-none} == selected && ! $modules =~ (^|$'\n')module-tunnel-source-new[[:space:]] ]]; then return 1; fi
		return 0
	fi
	[[ ${TG_MICROPHONE_MODE:-none} != selected ]] || return 1
	command -v pipewire >/dev/null || return 1
	# Unknown quirks are ignored by PipeWire. Check this installed capability
	# before relying on it; this project installs Debian's native packages.
	while IFS= read -r module; do
		[[ $module == */libpipewire-module-protocol-pulse.so ]] || continue
		if LC_ALL=C grep -aFq 'block-record-stream' "$module"; then
			TG_AUDIO_PROVIDER=pipewire
			return 0
		fi
	done < <(dpkg-query -L libpipewire-0.3-modules 2>/dev/null)
	return 1
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
	local notification_fd input_fd _ready host_socket status index identity description properties
	local started=$SECONDS remaining silence=telegram-silence
	local -A selected_names=()
	TG_AUDIO_PID=
	TG_AUDIO_DIR=
	TG_AUDIO_SOCKET=
	tg_audio_supported || {
		printf 'The installed native audio provider cannot isolate microphone input. Run ./telegram-setup.bash.\n' >&2
		return 1
	}
	[[ -n ${TG_RUNTIME:-} && $TG_RUNTIME == /* && -d $TG_RUNTIME ]] || return 1
	TG_AUDIO_DIR=$(mktemp -d "$TG_RUNTIME/telegram-audio.XXXXXX") || return 1
	chmod 700 -- "$TG_AUDIO_DIR" || { tg_audio_stop; return 1; }
	TG_AUDIO_SOCKET=$TG_AUDIO_DIR/native
	if [[ $TG_AUDIO_PROVIDER == pulseaudio ]]; then
		[[ -S ${TG_PULSE_SOCKET:-} ]] || { tg_audio_stop; return 1; }
		# PulseAudio startup syntax quotes backslashes and double quotes.
		host_socket=${TG_PULSE_SOCKET//\\/\\\\}
		host_socket=${host_socket//\"/\\\"}
		if [[ ${TG_MICROPHONE_MODE:-none} == selected ]]; then
			tg_microphones_discover "$TG_PULSE_SOCKET" || { tg_audio_stop; return 1; }
			for identity in "${TG_MICROPHONE_IDS[@]}"; do selected_names[$identity]=1; done
			while [[ ${selected_names[$silence]+present} ]]; do silence+=_; done
		fi
		{
			printf '.fail\n'
			printf 'load-module module-suspend-on-idle timeout=0\n'
			printf 'load-module module-switch-on-connect ignore_virtual=false blacklist=^$\n'
			printf 'load-module module-tunnel-sink-new server="unix:%s" sink_name=telegram-playback reconnect_interval_ms=1000\n' "$host_socket"
			printf 'load-module module-null-source source_name=%s\n' "$silence"
			printf 'set-default-source %s\n' "$silence"
			if [[ ${TG_MICROPHONE_MODE:-none} == selected ]]; then
				for index in "${!TG_MICROPHONES_IDS[@]}"; do
					[[ ${TG_MICROPHONES_SELECTED[index]} == yes && ${TG_MICROPHONES_CONNECTED[index]} == yes ]] || continue
					identity=${TG_MICROPHONES_IDS[index]}
					description=${TG_MICROPHONES_LABELS[index]//\\/ }
					description=${description//\'/}
					description=${description//\"/}
					properties="device.description='$description'"
					printf 'load-module module-tunnel-source-new server="unix:%s" source="%s" source_name="%s" source_properties="%s" reconnect_interval_ms=1000\n' "$host_socket" "$identity" "$identity" "$properties"
				done
			fi
			printf 'load-module module-native-protocol-unix socket=native auth-anonymous=true auth-cookie-enabled=false\n'
			# Only the launcher owns this inherited readiness pipe. It has no
			# socket, and unloads itself when the launcher closes the pipe.
			printf 'load-module module-cli exit_on_eof=false\n'
		} > "$TG_AUDIO_DIR/telegram-audio.pa"
	else
		cat > "$TG_AUDIO_DIR/telegram-audio.conf" <<'EOF'
context.properties = { core.daemon = false }
context.spa-libs = {
	audio.convert.* = audioconvert/libspa-audioconvert
	support.* = support/libspa-support
}
context.modules = [
	{ name = libpipewire-module-rt flags = [ ifexists nofail ] }
	{ name = libpipewire-module-protocol-native }
	{ name = libpipewire-module-client-node }
	{ name = libpipewire-module-adapter }
	{ name = libpipewire-module-metadata }
	{ name = libpipewire-module-protocol-pulse }
]
pulse.properties = {
	server.address = [ "unix:native" ]
	pulse.allow-module-loading = false
}
pulse.rules = [
	# Empty objects do not match in PipeWire rules. These complementary
	# predicates cover every client, including missing or changed names.
	{ matches = [ { application.name = null } { application.name = !null } ]
	  actions = { quirks = [ block-record-stream ] } }
]
EOF
	fi
	# Private configs load no capture hardware or host rules that undo isolation.
	# Readiness and process exit are native events; no socket polling is needed.
	coproc TG_AUDIO_READY {
		# Only this server's readiness pipes belong in the audio process.
		# In a Flatpak hook, inherited descriptors also control native proxies.
		tg_audio_close_fds
		export XDG_RUNTIME_DIR=$TG_RUNTIME
		export PULSE_RUNTIME_PATH=$TG_AUDIO_DIR
		if [[ $TG_AUDIO_PROVIDER == pulseaudio ]]; then
			# These stream properties prevent the desktop PipeWire policy from
			# substituting another source if an approved microphone disappears.
			export PULSE_PROP='node.dont-fallback=true node.dont-move=true'
			if [[ -n $TG_AUDIO_PRIVATE ]]; then export LD_BIND_NOW=1 LD_LIBRARY_PATH=$TG_AUDIO_PRIVATE/lib; fi
			export PULSE_STATE_PATH=$TG_AUDIO_DIR
			# libpulse may create a missing cookie, so keep its temporary
			# authentication data here too. Host Unix auth uses peer UID.
			export PULSE_COOKIE=$TG_AUDIO_DIR/cookie
			export DBUS_SESSION_BUS_ADDRESS=unix:path=$TG_AUDIO_DIR/no-session-bus
			# A new session prevents module-cli from opening the user's tty.
			exec setpriv --pdeathsig TERM -- setsid "$TG_AUDIO_BINARY" "${TG_AUDIO_PULSE_ARGS[@]}" --daemonize=no --use-pid-file=no \
				--disallow-module-loading=yes --disallow-exit=yes --exit-idle-time=-1 \
				--fail=yes --log-target=stderr --log-level=error -n -F "$TG_AUDIO_DIR/telegram-audio.pa"
		else
			export PIPEWIRE_CONFIG_DIR=$TG_AUDIO_DIR
			export PIPEWIRE_DAEMON=false
			export PIPEWIRE_PULSE_NOTIFICATION_FD=1
			exec setpriv --pdeathsig TERM -- pipewire -c telegram-audio.conf
		fi
	}
	TG_AUDIO_PID=${TG_AUDIO_READY_PID:-}
	notification_fd=${TG_AUDIO_READY[0]:-}
	input_fd=${TG_AUDIO_READY[1]:-}
	if [[ -z $TG_AUDIO_PID || -z $notification_fd || -z $input_fd ]]; then
		tg_audio_stop
		return 1
	fi
	if [[ $TG_AUDIO_PROVIDER == pulseaudio ]]; then
		# module-cli answers only once the protected native main loop runs.
		if ! printf 'hello\n' >&"$input_fd"; then
			exec {input_fd}>&-
			exec {notification_fd}<&-
			tg_audio_stop
			return 1
		fi
	else
		exec {input_fd}>&-
		input_fd=
	fi
	# This is the small native broker's readiness deadline, independent of
	# package downloads, Telegram startup, or application file loading.
	remaining=$((60 - (SECONDS - started)))
	if (( remaining > 0 )) && IFS= read -r -t "$remaining" -u "$notification_fd" _ready; then
		:
	else
		status=$?
		if (( status > 128 )); then
			printf 'The private %s audio server did not become ready within one minute.\n' "$TG_AUDIO_PROVIDER" >&2
			ps -o pid=,stat=,wchan:32=,comm= -p "$TG_AUDIO_PID" >&2 || true
			kill -KILL -- "$TG_AUDIO_PID" 2>/dev/null || true
		fi
		[[ -z $input_fd ]] || exec {input_fd}>&-
		exec {notification_fd}<&-
		tg_audio_stop
		printf 'The private restricted audio server failed to start.\n' >&2
		return 1
	fi
	if [[ $TG_AUDIO_PROVIDER == pulseaudio ]]; then exec {input_fd}>&-; fi
	exec {notification_fd}<&-
	[[ -S $TG_AUDIO_SOCKET ]] || { tg_audio_stop; return 1; }
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
