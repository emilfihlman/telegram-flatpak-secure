#!/usr/bin/env bash
# A private PipeWire graph is the audio boundary. Telegram receives only its
# PulseAudio socket; the host server and private PipeWire socket stay outside.
set -euo pipefail
umask 077
export LC_ALL=C

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
telegram_helper_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
telegram_microphones="$telegram_helper_dir/telegram-microphones.bash"
telegram_consent="$telegram_helper_dir/telegram-consent.bash"
# The installed config-path selects the same trusted settings used by the hook.
source "$telegram_helper_dir/telegram-common.bash"
tg_paths
tg_config_load required || fail 'The audio broker settings are invalid; run setup.'
telegram_run=
telegram_command_pid=
telegram_pipewire_pid=
telegram_wireplumber_pid=

cleanup() {
	local status=$? pid
	trap - EXIT INT TERM HUP
	# Killing the managed launcher also ends its --die-with-parent sandbox.
	if [[ -n $telegram_command_pid ]]; then kill -KILL "$telegram_command_pid" 2>/dev/null || true; fi
	for pid in "$telegram_wireplumber_pid" "$telegram_pipewire_pid"; do
		[[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null || true
	done
	for pid in "$telegram_command_pid" "$telegram_wireplumber_pid" "$telegram_pipewire_pid"; do
		[[ -z $pid ]] || wait "$pid" 2>/dev/null || true
	done
	[[ -z $telegram_run ]] || rm -rf -- "$telegram_run"
	exit "$status"
}

consent_snapshot() {
	local snapshot
	snapshot=$("$telegram_consent" snapshot) || fail 'Cannot read native microphone/camera consent.'
	[[ $snapshot =~ ^(yes|no)\ (yes|no)$ ]] || fail 'Invalid native microphone/camera consent state.'
	printf '%s\n' "$snapshot"
}

quote_config() {
	local text=$1
	text=${text//\\/\\\\}
	text=${text//\"/\\\"}
	text=${text//$'\n'/\\n}
	text=${text//$'\r'/\\r}
	text=${text//$'\t'/\\t}
	printf '"%s"' "$text"
}

write_config() {
	local source index=0
	{
		cat <<'CONFIG'
context.properties = {
	core.daemon = true
	core.name = pipewire-0
}
context.spa-libs = {
	audio.convert.* = audioconvert/libspa-audioconvert
	support.* = support/libspa-support
}
context.modules = [
	{ name = libpipewire-module-protocol-native }
	{ name = libpipewire-module-access args = {
		access.socket = { pipewire-0 = unrestricted pipewire-0-manager = unrestricted }
	} }
	{ name = libpipewire-module-metadata }
	{ name = libpipewire-module-spa-node-factory }
	{ name = libpipewire-module-client-node }
	{ name = libpipewire-module-adapter }
	{ name = libpipewire-module-link-factory }
	{ name = libpipewire-module-protocol-pulse }
CONFIG
		for source in "${telegram_sources[@]}"; do
			((index+=1))
			cat <<CONFIG
	{ name = libpipewire-module-pulse-tunnel args = {
		tunnel.mode = source
		pulse.server.address = $(quote_config "$telegram_host_server")
		target.object = $(quote_config "$source")
		reconnect.interval.ms = 0
		pulse.latency = 40
		stream.props = {
			node.name = telegram_mic_$index
			node.description = $(quote_config "$source")
			node.dont-fallback = true
			node.dont-reconnect = true
			node.dont-move = true
		}
	} }
CONFIG
		done
		cat <<CONFIG
	{ name = libpipewire-module-pulse-tunnel args = {
		tunnel.mode = sink
		pulse.server.address = $(quote_config "$telegram_host_server")
		target.object = $(quote_config "$telegram_host_sink")
		reconnect.interval.ms = 0
		pulse.latency = 40
		stream.props = {
			node.name = telegram_output
			node.description = "Telegram playback"
		}
	} }
]
pulse.properties = {
	server.address = [ $(quote_config "unix:$telegram_run/pulse/native") ]
	pulse.allow-module-loading = false
}
CONFIG
		cat <<'CONFIG'
pulse.rules = [
	{
		matches = [ { application.name = !null } { application.name = null } ]
		actions = {
			update-props = {
				node.dont-fallback = true
				node.dont-reconnect = true
				node.dont-move = true
				remote.intention = generic
			}
CONFIG
		if [[ $telegram_mic_allowed == no ]]; then
			# Denying the native microphone permission also denies recording the
			# private playback monitor; playback itself remains available.
			printf '\t\t\tquirks = [ block-record-stream ]\n'
		fi
		cat <<'CONFIG'
		}
	}
]
context.objects = [
	{ factory = spa-node-factory args = {
		factory.name = support.node.driver
		node.name = Dummy-Driver
		priority.driver = 200000
	} }
]
CONFIG
	} > "$telegram_run/core/pipewire.conf"

	# Use the distribution's policy code without host/user config fragments or
	# device discovery. Native consent is supervised by the outer guardian.
	cp -- "$telegram_wp_data/wireplumber.conf" "$telegram_run/wireplumber/wireplumber.conf"
	mkdir -- "$telegram_run/wireplumber/wireplumber.conf.d"
	cat > "$telegram_run/wireplumber/wireplumber.conf.d/99-telegram.conf" <<'CONFIG'
wireplumber.profiles = {
	telegram = {
		inherits = [ policy, mixin.systemwide-session, mixin.stateless ]
		hardware.audio = disabled
		hardware.bluetooth = disabled
		hardware.video-capture = disabled
		support.dbus = disabled
		support.portal-permissionstore = disabled
		script.client.access-portal = disabled
	}
}
CONFIG
}

start_daemons() {
	# PIPEWIRE_REMOTE must be in the trusted process environment. Otherwise a
	# malicious Pulse client can supply remote.name to redirect its connection.
	# PULSE_PROP_OVERRIDE reaches the host record stream through libpulse and
	# pipewire-pulse. DONT_MOVE alone does not disable initial WP fallback.
	local -a daemon_env=(
		-u PIPEWIRE_CONFIG_NAME -u PIPEWIRE_CONFIG_PREFIX
		-u PIPEWIRE_CORE -u PIPEWIRE_DAEMON -u PIPEWIRE_PROPS
		-u PIPEWIRE_MODULE_DIR -u SPA_PLUGIN_DIR
		-u WIREPLUMBER_MODULE_DIR -u WIREPLUMBER_PROFILE
		-u PULSE_CLIENTCONFIG -u PULSE_COOKIE
		-u PULSE_SERVER -u PULSE_SOURCE -u PULSE_SINK
		"XDG_RUNTIME_DIR=$telegram_run"
		"XDG_STATE_HOME=$telegram_run/state"
		"XDG_CONFIG_HOME=$telegram_run/config"
		"PIPEWIRE_RUNTIME_DIR=$telegram_run/core"
		"PIPEWIRE_REMOTE=pipewire-0"
		"PIPEWIRE_CONFIG_DIR=$telegram_run/core"
		"PULSE_RUNTIME_PATH=$telegram_run/pulse"
		"PULSE_PROP_OVERRIDE=node.dont-fallback=true node.dont-reconnect=true node.dont-move=true"
		"DBUS_SESSION_BUS_ADDRESS=unix:path=/dev/null"
		"DBUS_SYSTEM_BUS_ADDRESS=unix:path=/dev/null"
	)
	# Keep the daemon lifetime attached even if this supervisor is killed
	# without running traps. Host PIDs and the mapped user identity stay intact.
	bwrap --unshare-user --die-with-parent --bind / / -- \
		env "${daemon_env[@]}" pipewire -c "$telegram_run/core/pipewire.conf" > "$telegram_run/pipewire.log" 2>&1 &
	telegram_pipewire_pid=$!
	printf '%s\n' "$telegram_pipewire_pid" > "$telegram_run/pipewire.pid"
	local attempt
	for (( attempt=0; attempt<50; attempt++ )); do
		kill -0 "$telegram_pipewire_pid" 2>/dev/null || {
			tail -n 10 -- "$telegram_run/pipewire.log" >&2
			fail 'The private audio server could not start.'
		}
		[[ ! -S $telegram_run/core/pipewire-0 ]] || break
		sleep 0.1
	done
	[[ -S $telegram_run/core/pipewire-0 ]] || fail 'The private audio graph did not become ready.'
	bwrap --unshare-user --die-with-parent --bind / / -- \
		env "${daemon_env[@]}" \
		"WIREPLUMBER_CONFIG_DIR=$telegram_run/wireplumber" \
		"WIREPLUMBER_DATA_DIR=$telegram_wp_data" \
		wireplumber -p telegram > "$telegram_run/wireplumber.log" 2>&1 &
	telegram_wireplumber_pid=$!
	printf '%s\n' "$telegram_wireplumber_pid" > "$telegram_run/wireplumber.pid"
}

check_graph() {
	local sources sinks modules index name rest
	local -A expected=([telegram_output.monitor]=1)
	local -A expected_modules=(
		[libpipewire-module-protocol-native]=1
		[libpipewire-module-access]=1
		[libpipewire-module-metadata]=1
		[libpipewire-module-spa-node-factory]=1
		[libpipewire-module-client-node]=1
		[libpipewire-module-adapter]=1
		[libpipewire-module-link-factory]=1
		[libpipewire-module-protocol-pulse]=1
		[libpipewire-module-pulse-tunnel]=$(( ${#telegram_sources[@]} + 1 ))
	)
	for index in "${!telegram_sources[@]}"; do expected[telegram_mic_$((index + 1))]=1; done
	sources=$(timeout 3 pactl --server="$telegram_private_server" list short sources 2>/dev/null) || return 1
	while IFS=$'\t' read -r index name rest; do
		[[ -n $name ]] || continue
		[[ ${expected[$name]+present} ]] || fail "Unexpected recording source in private audio graph: $name"
		unset 'expected[$name]'
	done <<< "$sources"
	(( ${#expected[@]} == 0 )) || return 1
	sinks=$(timeout 3 pactl --server="$telegram_private_server" list short sinks 2>/dev/null) || return 1
	[[ $(printf '%s\n' "$sinks" | cut -f 2) == telegram_output ]] || return 1
	modules=$(timeout 3 pactl --server="$telegram_private_server" list short modules 2>/dev/null) || return 1
	# PipeWire exposes native core modules through pactl as well as modules
	# requested through the Pulse protocol. Verify the complete native set.
	while IFS=$'\t' read -r index name rest; do
		[[ -n $name ]] || continue
		[[ ${expected_modules[$name]+present} ]] || fail "Unexpected module in private audio graph: $name"
		(( expected_modules[$name] > 0 )) || fail "Unexpected duplicate module in private audio graph: $name"
		expected_modules[$name]=$(( expected_modules[$name] - 1 ))
	done <<< "$modules"
	for name in "${!expected_modules[@]}"; do (( expected_modules[$name] == 0 )) || return 1; done
}

run_audio() {
	local required attempt module_output capture_output finished status wp_binary telegram_camera_allowed
	local -a telegram_sources=()
	[[ ${1:-} != -- ]] || shift
	(( $# > 0 )) || fail 'No command supplied to the private audio launcher.'
	for required in bwrap pipewire wireplumber pactl parec timeout; do
		command -v "$required" >/dev/null || fail "Required audio tool is missing: $required. Run setup."
	done
	[[ -x $telegram_microphones ]] || fail 'The microphone grant helper is missing; run setup.'
	[[ -x $telegram_consent ]] || fail 'The native consent helper is missing; run setup.'
	[[ ${XDG_RUNTIME_DIR:-} == /* && -d $XDG_RUNTIME_DIR && -O $XDG_RUNTIME_DIR ]] || fail 'A user-owned XDG_RUNTIME_DIR is required.'
	telegram_consent_snapshot=$(consent_snapshot)
	[[ ${TELEGRAM_EXPECTED_CONSENT:-} =~ ^(yes|no)\ (yes|no)$ && $telegram_consent_snapshot == "$TELEGRAM_EXPECTED_CONSENT" ]] ||
		fail 'Native device consent changed before audio startup; relaunch Telegram.'
	read -r telegram_mic_allowed telegram_camera_allowed <<< "$telegram_consent_snapshot"
	# Native consent and the configured device selection are both required.
	[[ $TG_MICROPHONE_MODE != none ]] || telegram_mic_allowed=no
	mkdir -p -- "$XDG_RUNTIME_DIR/telegram-audio"
	[[ -d $XDG_RUNTIME_DIR/telegram-audio && -O $XDG_RUNTIME_DIR/telegram-audio && ! -L $XDG_RUNTIME_DIR/telegram-audio ]] || fail 'Invalid private audio runtime directory.'
	chmod 700 -- "$XDG_RUNTIME_DIR/telegram-audio"
	telegram_run=$(mktemp -d "$XDG_RUNTIME_DIR/telegram-audio/instance.XXXXXX")
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM HUP
	mkdir -- "$telegram_run/core" "$telegram_run/pulse" "$telegram_run/wireplumber" "$telegram_run/state" "$telegram_run/config"
	printf '%s\n' "$$" > "$telegram_run/launcher.pid"
	telegram_host_server=$("$telegram_microphones" server)
	"$telegram_microphones" resolve > "$telegram_run/sources"
	mapfile -d '' -t telegram_sources < "$telegram_run/sources"
	if [[ $telegram_mic_allowed == no ]]; then
		(( ${#telegram_sources[@]} == 0 )) || fail 'Microphones were resolved while native microphone consent is denied.'
	fi
	telegram_host_sink=$(timeout 5 pactl --server="$telegram_host_server" get-default-sink) || fail 'Cannot determine the host playback device.'
	[[ $telegram_host_sink =~ ^[A-Za-z0-9_.:-]+$ && ${#telegram_host_sink} -le 255 ]] || fail 'Unsupported host playback device name.'
	[[ $(consent_snapshot) == "$telegram_consent_snapshot" ]] || fail 'Native microphone/camera consent changed during startup; relaunch Telegram.'
	printf '%s\n' "$telegram_host_server" > "$telegram_run/host-server"
	printf '%s\n' "$telegram_consent_snapshot" > "$telegram_run/consent.snapshot"
	wp_binary=$(readlink -f -- "$(command -v wireplumber)")
	telegram_wp_data="$(dirname -- "$(dirname -- "$wp_binary")")/share/wireplumber"
	[[ -r $telegram_wp_data/wireplumber.conf ]] || fail 'The WirePlumber distribution configuration is missing.'
	telegram_private_server="unix:$telegram_run/pulse/native"
	write_config
	start_daemons
	for (( attempt=0; attempt<50; attempt++ )); do
		kill -0 "$telegram_pipewire_pid" "$telegram_wireplumber_pid" 2>/dev/null || {
			tail -n 10 -- "$telegram_run/pipewire.log" "$telegram_run/wireplumber.log" >&2
			fail 'The private audio service stopped during startup.'
		}
		if check_graph; then break; fi
		sleep 0.1
	done
	check_graph || fail 'The private audio graph did not expose exactly the approved microphones and playback sink.'
	if module_output=$(timeout 3 pactl --server="$telegram_private_server" load-module module-null-sink sink_name=telegram_denied_probe 2>&1); then
		fail 'The private audio server allowed module loading; Telegram was not started.'
	fi
	[[ $module_output == *'Access denied'* ]] || fail 'Could not verify that the private audio server denies module loading.'
	if [[ $telegram_mic_allowed == no ]]; then
		if capture_output=$(timeout 3 parec --server="$telegram_private_server" --device=telegram_output.monitor --raw 2>&1 > /dev/null); then
			fail 'Recording succeeded while native microphone consent is denied; Telegram was not started.'
		fi
		[[ $capture_output == *'Access denied'* ]] || fail 'Could not verify that denied native microphone consent blocks recording.'
	fi
	[[ $(consent_snapshot) == "$telegram_consent_snapshot" ]] || fail 'Native microphone/camera consent changed during startup; relaunch Telegram.'
	: > "$telegram_run/ready"
	PULSE_SERVER="$telegram_private_server" bwrap --unshare-user --die-with-parent --bind / / -- "$@" &
	telegram_command_pid=$!
	printf '%s\n' "$telegram_command_pid" > "$telegram_run/command.pid"
	set +e
	wait -n -p finished "$telegram_command_pid" "$telegram_pipewire_pid" "$telegram_wireplumber_pid"
	status=$?
	set -e
	if [[ ${finished:-} == "$telegram_command_pid" ]]; then
		telegram_command_pid=
	else
		[[ ${finished:-} != "$telegram_pipewire_pid" ]] || telegram_pipewire_pid=
		[[ ${finished:-} != "$telegram_wireplumber_pid" ]] || telegram_wireplumber_pid=
		fail 'The private audio service stopped; Telegram was closed.'
	fi
	exit "$status"
}

case ${1:-} in
	--serve)
		# The native sandbox sync pipe is supervised by telegram-audio.bash.
		# Announce readiness only after the graph and deny rules were verified.
		run_audio /usr/bin/bash -c 'printf "%s\n" "${PULSE_SERVER#unix:}"; exec sleep infinity'
		;;
	--run) shift; run_audio "$@" ;;
	--host-server) "$telegram_microphones" server ;;
	*) fail 'Usage: telegram-audio-broker.bash --serve | --run -- COMMAND [ARGUMENTS...] | --host-server' ;;
esac
