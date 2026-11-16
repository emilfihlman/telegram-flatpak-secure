#!/usr/bin/env bash
# Native desktop consent is the only microphone/camera permission store.
# The launcher and audio broker enforce these bits even where upstream audio
# policy would otherwise ignore them. A change closes the running sandbox.
set -euo pipefail
umask 077
export LC_ALL=C

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
telegram_app=org.telegram.desktop
telegram_store=org.freedesktop.impl.portal.PermissionStore
telegram_privacy_schema=org.gnome.desktop.privacy
telegram_has_global_privacy=no
telegram_run=
telegram_command_pid=
telegram_monitor_pid=
telegram_reader_pid=

require_commands() {
	local command
	for command in flatpak gsettings busctl timeout awk; do
		command -v "$command" >/dev/null || fail "Required command is unavailable: $command"
	done
}

prepare_globals() {
	local schemas
	schemas=$(timeout 5 gsettings list-schemas) || fail 'Cannot inspect native privacy settings.'
	if [[ $'\n'$schemas$'\n' != *$'\n'"$telegram_privacy_schema"$'\n'* ]]; then
		return
	fi
	# These are the GNOME desktop's normal native dconf settings. Do not read
	# a memory/keyfile backend while only watching dconf notifications.
	[[ -z ${GSETTINGS_BACKEND:-} || $GSETTINGS_BACKEND == dconf ]] ||
		fail 'Native privacy monitoring requires the dconf GSettings backend; unset GSETTINGS_BACKEND.'
	[[ -z ${GSETTINGS_SCHEMA_DIR:-} ]] ||
		fail 'Native privacy monitoring does not support GSETTINGS_SCHEMA_DIR overrides.'
	[[ -z ${DCONF_PROFILE:-} || $DCONF_PROFILE == user ]] ||
		fail 'Native privacy monitoring requires the default user dconf profile.'
	telegram_has_global_privacy=yes
}

native_records() {
	local records
	# Captured stdout is non-TTY: Flatpak emits five TSV columns and no title.
	# Data is deliberately ignored, never evaluated as shell or GVariant code.
	records=$(timeout 5 env -u FLATPAK_FANCY_OUTPUT flatpak permission-show "$telegram_app") ||
		fail 'Cannot read the native microphone/camera permission store.'
	printf '%s\n' "$records" | awk -F '\t' -v app="$telegram_app" '
		BEGIN { microphone="missing"; camera="missing" }
		/^$/ { next }
		NF < 5 || $3 != app { bad=1; next }
		$1 == "devices" && ($2 == "microphone" || $2 == "camera") {
			if (seen[$2]++) bad=1
			# Missing, ask, empty, and every value other than exactly yes deny.
			value=($4 == "yes" ? "yes" : "no")
			if ($2 == "microphone") microphone=value
			else camera=value
		}
		END {
			if (bad) exit 1
			print microphone " " camera
		}
	' || fail 'Unexpected native permission-table format.'
}

global_disabled() {
	local value
	# A missing backend can produce a warning and fall back to memory while
	# returning success. Treat every result except one plain boolean as failure.
	value=$(timeout 5 env GSETTINGS_BACKEND=dconf gsettings get "$telegram_privacy_schema" "disable-$1" 2>&1) ||
		fail "Cannot read the native global $1 privacy setting."
	case $value in
		true|false) printf '%s\n' "$value" ;;
		*) fail "Invalid native global $1 privacy setting or missing dconf backend." ;;
	esac
}

snapshot() {
	local records microphone camera disabled
	records=$(native_records) || return 1
	microphone=${records%% *}
	camera=${records#* }
	[[ $microphone == yes ]] || microphone=no
	[[ $camera == yes ]] || camera=no
	if [[ $telegram_has_global_privacy == yes ]]; then
		disabled=$(global_disabled microphone) || return 1
		[[ $disabled == false ]] || microphone=no
		disabled=$(global_disabled camera) || return 1
		[[ $disabled == false ]] || camera=no
	fi
	printf '%s %s\n' "$microphone" "$camera"
}

store_owner() {
	local owner
	owner=$(timeout 5 busctl --user --no-pager call org.freedesktop.DBus /org/freedesktop/DBus \
		org.freedesktop.DBus GetNameOwner s "$telegram_store") ||
		fail 'The native permission-store service is unavailable.'
	[[ $owner =~ ^s\ \"\:[0-9]+\.[0-9]+\"$ ]] || fail 'Invalid native permission-store service owner.'
}

init_consent() {
	local device records state
	for device in microphone camera; do
		# Re-read before each insertion; preserve all existing choices, including
		# ask/no. PermissionStore has no atomic insert-if-absent method.
		records=$(native_records) || return 1
		if [[ $device == microphone ]]; then state=${records%% *}; else state=${records#* }; fi
		if [[ $state == missing ]]; then
			timeout 5 flatpak permission-set devices "$device" "$telegram_app" no ||
				fail "Cannot initialize native $device consent."
		fi
	done
	store_owner
}

set_consent() {
	local device=$1 value=$2 records actual
	[[ $device == microphone || $device == camera ]] || fail 'Choose microphone or camera.'
	[[ $value == yes || $value == no ]] || fail 'Consent must be yes or no.'
	timeout 5 flatpak permission-set devices "$device" "$telegram_app" "$value" ||
		fail "Cannot update native $device consent."
	records=$(native_records) || return 1
	if [[ $device == microphone ]]; then actual=${records%% *}; else actual=${records#* }; fi
	[[ $actual == "$value" ]] || fail "The native $device consent update could not be verified."
}

cleanup() {
	local status=$? pid attempt
	trap - EXIT INT TERM HUP
	# Give the managed audio supervisor time to clean up its private broker.
	if [[ -n $telegram_command_pid ]]; then
		kill -TERM "$telegram_command_pid" 2>/dev/null || true
		for ((attempt=0; attempt<40; attempt++)); do
			kill -0 "$telegram_command_pid" 2>/dev/null || break
			sleep 0.05
		done
		kill -KILL "$telegram_command_pid" 2>/dev/null || true
		wait "$telegram_command_pid" 2>/dev/null || true
		telegram_command_pid=
	fi
	for pid in "$telegram_reader_pid" "$telegram_monitor_pid"; do
		[[ -z $pid ]] || kill -TERM "$pid" 2>/dev/null || true
	done
	for pid in "$telegram_reader_pid" "$telegram_monitor_pid"; do
		[[ -z $pid ]] || wait "$pid" 2>/dev/null || true
	done
	[[ -z $telegram_run ]] || rm -rf -- "$telegram_run"
	exit "$status"
}

read_events() {
	local expected=$1 line current ready=no
	# This child never owns the command or other child PIDs.
	trap - EXIT INT TERM HUP
	while IFS= read -r line; do
		if [[ $line == 'Monitoring bus message stream.' ]]; then
			[[ $ready == no ]] || fail 'Duplicate native permission monitor readiness message.'
			ready=yes
			: > "$telegram_run/ready"
			continue
		fi
		case $line in
			*'Interface=org.freedesktop.DBus  Member=NameOwnerChanged'*)
				fail 'The native permission-store service changed or disappeared; closing Telegram.' ;;
			*'Interface=org.freedesktop.impl.portal.PermissionStore  Member=Changed'*|\
			*'Interface=ca.desrt.dconf.Writer  Member=Notify'*)
				[[ $ready == yes ]] || fail 'Native privacy event arrived before monitoring was ready.'
				current=$(snapshot) || fail 'Cannot verify native device consent; closing Telegram.'
				[[ $current == "$expected" ]] ||
					fail 'Native microphone/camera consent changed; closing Telegram. Relaunch to apply it.'
				;;
			*'Interface=org.freedesktop.DBus.Local  Member=Disconnected'*)
				fail 'The session bus disconnected; closing Telegram.' ;;
		esac
	done
	fail 'Native privacy monitoring stopped; closing Telegram.'
}

run_guarded() {
	local expected=$1 current attempt completed= status=0 command
	shift
	[[ $expected =~ ^(yes|no)\ (yes|no)$ ]] || fail 'Invalid expected native consent snapshot.'
	[[ ${1:-} == -- ]] || fail 'Expected -- before the managed command.'
	shift
	(( $# > 0 )) || fail 'A managed command is required.'
	for command in bwrap mktemp mkfifo; do
		command -v "$command" >/dev/null || fail "Required command is unavailable: $command"
	done
	[[ ${XDG_RUNTIME_DIR:-} == /* && -d $XDG_RUNTIME_DIR && -O $XDG_RUNTIME_DIR ]] ||
		fail 'A user-owned XDG_RUNTIME_DIR is required.'
	# Activate and check the service before watching ownership. The fresh,
	# authoritative launch check occurs only after BecomeMonitor completes.
	current=$(snapshot) || fail 'Cannot verify native device consent.'
	store_owner
	telegram_run=$(mktemp -d "$XDG_RUNTIME_DIR/telegram-consent.XXXXXX")
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	mkfifo -- "$telegram_run/events"
	read_events "$expected" < "$telegram_run/events" &
	telegram_reader_pid=$!
	# busctl emits its readiness line only after synchronous BecomeMonitor.
	# gdbus monitor's banner is earlier than signal subscription and cannot
	# provide this barrier. Plain text is used only for fixed member headers;
	# all permission/settings values are queried through their normal CLIs.
	local -a monitor=(
		busctl --user --no-pager
		--match="type='signal',sender='$telegram_store',path='/org/freedesktop/impl/portal/PermissionStore',interface='$telegram_store',member='Changed',arg0='devices',arg1='microphone'"
		--match="type='signal',sender='$telegram_store',path='/org/freedesktop/impl/portal/PermissionStore',interface='$telegram_store',member='Changed',arg0='devices',arg1='camera'"
		--match="type='signal',sender='org.freedesktop.DBus',path='/org/freedesktop/DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='$telegram_store'"
	)
	if [[ $telegram_has_global_privacy == yes ]]; then
		monitor+=(--match="type='signal',sender='ca.desrt.dconf',interface='ca.desrt.dconf.Writer',member='Notify'")
	fi
	env -u NOTIFY_SOCKET SYSTEMD_LOG_LEVEL=info SYSTEMD_LOG_TARGET=console \
		SYSTEMD_COLORS=0 SYSTEMD_LOG_COLOR=0 SYSTEMD_LOG_LOCATION=0 \
		"${monitor[@]}" monitor > "$telegram_run/events" 2>&1 &
	telegram_monitor_pid=$!
	for ((attempt=0; attempt<100; attempt++)); do
		[[ ! -f $telegram_run/ready ]] || break
		kill -0 "$telegram_monitor_pid" 2>/dev/null && kill -0 "$telegram_reader_pid" 2>/dev/null ||
			fail 'Cannot establish native privacy monitoring.'
		sleep 0.05
	done
	[[ -f $telegram_run/ready ]] || fail 'Timed out establishing native privacy monitoring.'
	current=$(snapshot) || fail 'Cannot verify native device consent after starting monitoring.'
	store_owner
	[[ $current == "$expected" ]] || fail 'Native device consent changed during launch; relaunch Telegram.'
	kill -0 "$telegram_monitor_pid" 2>/dev/null && kill -0 "$telegram_reader_pid" 2>/dev/null ||
		fail 'Native privacy monitoring failed during launch.'
	# Parent death must close the entire managed chain, including an unexpected
	# SIGKILL of this guardian. This outer layer preserves the host filesystem;
	# the later launcher provides device filtering and Flatpak's sandbox.
	bwrap --unshare-user --die-with-parent --bind / / -- "$@" &
	telegram_command_pid=$!
	if wait -n -p completed "$telegram_command_pid" "$telegram_monitor_pid" "$telegram_reader_pid"; then
		status=0
	else
		status=$?
	fi
	# Clear reaped PIDs before cleanup; never send a signal to those old IDs.
	case ${completed:-} in
		"$telegram_command_pid") telegram_command_pid=; exit "$status" ;;
		"$telegram_monitor_pid") telegram_monitor_pid=; fail 'Native privacy monitor exited; closing Telegram.' ;;
		"$telegram_reader_pid") telegram_reader_pid=; fail 'Native privacy supervision ended; closing Telegram.' ;;
		*) fail 'Native privacy supervision was interrupted; closing Telegram.' ;;
	esac
}

require_commands
prepare_globals
case ${1:-} in
	init) (( $# == 1 )) || fail 'Usage: telegram-consent.bash init'; init_consent ;;
	snapshot) (( $# == 1 )) || fail 'Usage: telegram-consent.bash snapshot'; snapshot ;;
	set) (( $# == 3 )) || fail 'Usage: telegram-consent.bash set {microphone|camera} {yes|no}'; set_consent "$2" "$3" ;;
	--run) (( $# >= 4 )) || fail 'Usage: telegram-consent.bash --run "MICROPHONE CAMERA" -- COMMAND...'; shift; run_guarded "$@" ;;
	*) fail 'Usage: telegram-consent.bash {init|snapshot|set {microphone|camera} {yes|no}|--run "MICROPHONE CAMERA" -- COMMAND...}' ;;
esac
