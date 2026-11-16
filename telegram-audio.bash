#!/usr/bin/env bash
# A private native Pulse server withholds microphones and retains playback.

tg_audio_supported() {
	local module modules
	command -v setpriv >/dev/null && command -v setsid >/dev/null || return 1
	if command -v pulseaudio >/dev/null; then
		modules=$(pulseaudio --dump-modules) || return 1
		for module in module-native-protocol-unix module-tunnel-sink-new module-null-source module-cli; do
			[[ $modules =~ (^|$'\n')${module}[[:space:]] ]] || return 1
		done
		TG_AUDIO_PROVIDER=pulseaudio
		return 0
	fi
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
	local notification_fd input_fd _ready host_socket status
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
		{
			printf '.fail\n'
			printf 'load-module module-tunnel-sink-new server="unix:%s" sink_name=telegram-playback reconnect_interval_ms=1000\n' "$host_socket"
			printf 'load-module module-null-source source_name=telegram-silence\n'
			printf 'set-default-source telegram-silence\n'
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
		export XDG_RUNTIME_DIR=$TG_RUNTIME
		export PULSE_RUNTIME_PATH=$TG_AUDIO_DIR
		if [[ $TG_AUDIO_PROVIDER == pulseaudio ]]; then
			export PULSE_STATE_PATH=$TG_AUDIO_DIR
			# libpulse may create a missing cookie, so keep its temporary
			# authentication data here too. Host Unix auth uses peer UID.
			export PULSE_COOKIE=$TG_AUDIO_DIR/cookie
			export DBUS_SESSION_BUS_ADDRESS=unix:path=$TG_AUDIO_DIR/no-session-bus
			# A new session prevents module-cli from opening the user's tty.
			exec setpriv --pdeathsig TERM -- setsid pulseaudio --daemonize=no --use-pid-file=no \
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
	if IFS= read -r -t 60 -u "$notification_fd" _ready; then
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
		printf 'The private playback-only Pulse server failed to start.\n' >&2
		return 1
	fi
	if [[ $TG_AUDIO_PROVIDER == pulseaudio ]]; then exec {input_fd}>&-; fi
	exec {notification_fd}<&-
	[[ -S $TG_AUDIO_SOCKET ]] || { tg_audio_stop; return 1; }
}
