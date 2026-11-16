#!/usr/bin/bash
# Add selected media mounts to Flatpak's native sandbox without broad device grants.
set -euo pipefail

tg_bwrap_inspect() {
	local descriptor index metadata_fd='' section='' line application='' marker=no name namespace grant unsafe_bus=no
	local -a packed=()
	TG_BWRAP_APP=no
	TG_BWRAP_SANDBOX=no
	TG_BWRAP_PULSE_SOCKET=
	TG_BWRAP_SYNC_INDEX=
	TG_BWRAP_SYNC_FD=
	TG_BWRAP_PACKED=()
	case ${1:-} in
		--args) descriptor=${2:-} ;;
		--args=*) descriptor=${1#--args=} ;;
		*) return 0 ;;
	esac
	[[ $descriptor =~ ^[0-9]+$ && -r /proc/self/fd/$descriptor ]] || return 1
	# Opening the descriptor path creates a separate offset. Bubblewrap still
	# receives Flatpak's original packed arguments and every original descriptor.
	mapfile -d '' -t packed < "/proc/self/fd/$descriptor" || return 1
	TG_BWRAP_ARGS_FD=$descriptor
	for ((index=0; index < ${#packed[@]}; index++)); do
		case ${packed[index]} in
			--setenv)
				(( index + 2 < ${#packed[@]} )) || return 1
				case ${packed[index+1]} in
					TELEGRAM_WRAPPER) [[ ${packed[index+2]} != telegram-sandbox ]] || marker=yes ;;
				esac
				index=$((index + 2)) ;;
			--ro-bind-data)
				(( index + 2 < ${#packed[@]} )) || return 1
				if [[ ${packed[index+2]} == /.flatpak-info ]]; then metadata_fd=${packed[index+1]}; fi
				index=$((index + 2)) ;;
			--sync-fd)
				(( index + 1 < ${#packed[@]} )) || return 1
				TG_BWRAP_SYNC_INDEX=$((index + 1))
				TG_BWRAP_SYNC_FD=${packed[index+1]}
				[[ $TG_BWRAP_SYNC_FD =~ ^[0-9]+$ && -e /proc/self/fd/$TG_BWRAP_SYNC_FD ]] || return 1
				index=$((index + 1)) ;;
		esac
	done
	TG_BWRAP_PACKED=("${packed[@]}")
	[[ -n $metadata_fd ]] || return 0
	[[ $metadata_fd =~ ^[0-9]+$ && -r /proc/self/fd/$metadata_fd ]] || return 1
	while IFS= read -r line || [[ -n $line ]]; do
		case $line in
			\[*\]) section=$line ;;
			name=*) [[ $section != '[Application]' ]] || application=${line#name=} ;;
			sandbox=true) [[ $section != '[Instance]' ]] || TG_BWRAP_SANDBOX=yes ;;
		esac
		if [[ $section == '[Session Bus Policy]' && $line == *=* ]]; then
			name=${line%%=*}
			grant=${line#*=}
			if [[ $grant == talk || $grant == own ]]; then
				# Native namespace wildcards include their root as well as children.
				namespace=
				[[ $name != *'.*' ]] || namespace=${name%'.*'}
				# shellcheck disable=SC2053
				if [[ org.freedesktop.Flatpak == $name || org.freedesktop.systemd1 == $name ||
					org.freedesktop.Flatpak == "$namespace" || org.freedesktop.systemd1 == "$namespace" ]]; then unsafe_bus=yes; fi
			fi
		fi
	done < "/proc/self/fd/$metadata_fd"
	[[ $application != org.telegram.desktop || $marker != yes ]] || TG_BWRAP_APP=yes
	if [[ $TG_BWRAP_APP == yes && $unsafe_bus == yes ]]; then
		printf 'Error: inherited Telegram permissions allow host control through D-Bus. Remove that grant before launching.\n' >&2
		return 1
	fi
}

tg_bwrap_audio() {
	local directory permissions suffix
	if [[ $TG_MICROPHONE_MODE == all ]]; then
		TG_BWRAP_PULSE_SOCKET=$TG_PULSE_SOCKET
	else
		# Each native sandbox gets its own broker. An update creates a new
		# sandbox; an ordinary relaunch retains this sandbox's sync pipe.
		coproc TG_BWRAP_AUDIO { tg_audio_sandbox "$TG_BWRAP_SYNC_FD"; }
		TG_BWRAP_OWNER_PID=${TG_BWRAP_AUDIO_PID:-}
		local notification_fd=${TG_BWRAP_AUDIO[0]} input_fd=${TG_BWRAP_AUDIO[1]}
		# A shell dup retains a coprocess FD's close-on-exec bit. Reopen its
		# pipe so the native bwrap process can inherit the lifetime writer.
		exec {TG_BWRAP_AUDIO_FD}> "/proc/self/fd/$input_fd"
		exec {input_fd}>&-
		trap 'tg_bwrap_audio_abort' EXIT
		trap 'exit 129' HUP
		trap 'exit 130' INT
		trap 'exit 143' TERM
		if ! IFS= read -r -t 60 -u "$notification_fd" TG_BWRAP_PULSE_SOCKET; then
			exec {notification_fd}<&-
			return 1
		fi
		exec {notification_fd}<&-
		if [[ -n $TG_BWRAP_SYNC_INDEX ]]; then
			TG_BWRAP_PACKED[TG_BWRAP_SYNC_INDEX]=$TG_BWRAP_AUDIO_FD
			exec {TG_BWRAP_SYNC_FD}>&-
		else
			TG_BWRAP_PACKED+=(--sync-fd "$TG_BWRAP_AUDIO_FD")
		fi
		# Keep native argument/metadata FDs intact, including large argument
		# lists; only the one sync handle changes. Released bwrap accepts one.
		exec {TG_BWRAP_ARGS_FD}<&-
		exec {TG_BWRAP_REPLACEMENT_FD}< <(printf '%s\0' "${TG_BWRAP_PACKED[@]}")
		directory=${TG_BWRAP_PULSE_SOCKET%/native}
		suffix=${directory#"$TG_RUNTIME/telegram-audio."}
		[[ $suffix =~ ^[A-Za-z0-9]{6}$ && $TG_BWRAP_PULSE_SOCKET == "$TG_RUNTIME/telegram-audio.$suffix/native" ]] || return 1
		[[ -d $directory && ! -L $directory && -O $directory ]] || return 1
		permissions=$(stat -Lc '%a' -- "$directory") || return 1
		[[ $permissions == 700 ]] || return 1
	fi
	[[ -S $TG_BWRAP_PULSE_SOCKET && ! -L $TG_BWRAP_PULSE_SOCKET && -O $TG_BWRAP_PULSE_SOCKET ]] || return 1
	TG_BWRAP_MEDIA+=(--ro-bind "$TG_BWRAP_PULSE_SOCKET" /run/flatpak/pulse/native
		--setenv PULSE_SERVER unix:/run/flatpak/pulse/native --unsetenv PULSE_CLIENTCONFIG
		--setenv TELEGRAM_AUDIO_SOCKET_ID "$(stat -Lc '%d:%i' -- "$TG_BWRAP_PULSE_SOCKET")")
}

tg_bwrap_audio_abort() {
	if [[ -n ${TG_BWRAP_AUDIO_FD:-} ]]; then exec {TG_BWRAP_AUDIO_FD}>&-; fi
	if [[ -n ${TG_BWRAP_OWNER_PID:-} ]]; then
		kill -TERM -- "$TG_BWRAP_OWNER_PID" 2>/dev/null || true
		wait "$TG_BWRAP_OWNER_PID" 2>/dev/null || true
	fi
}

main() {
	local sibling node argument inserted=no replace_args=no
	local -a forwarded=()
	tg_bwrap_inspect "$@" || { printf 'Error: could not read Flatpak sandbox arguments.\n' >&2; return 1; }
	[[ $TG_BWRAP_APP == yes ]] || exec /usr/bin/bwrap "$@"
	sibling=${BASH_SOURCE[0]%/*}
	# Flatpak launches bubblewrap with an empty environment. Installed config-path
	# points to trusted settings, independently of HOME or caller-supplied variables.
	source "$sibling/telegram-common.bash"
	tg_paths
	tg_config_load required
	source "$sibling/telegram-media.bash"
	source "$sibling/telegram-audio.bash"
	TG_BWRAP_MEDIA=()
	if [[ $TG_BWRAP_SANDBOX != yes ]]; then
		tg_media_resolve
		for node in "${TG_CAMERA_NODES[@]}"; do
			TG_BWRAP_MEDIA+=(--dev-bind "$node" "$node")
		done
	fi
	# Flatpak's pulseaudio grant also exposes raw ALSA. Keep that grant disabled
	# and mount only the approved Pulse socket, including for WebKit children.
	tg_bwrap_audio || { printf 'Error: the configured audio connection is unavailable.\n' >&2; return 1; }
	for argument in "$@"; do
		if [[ $inserted == no && -n ${TG_BWRAP_REPLACEMENT_FD:-} ]]; then
			if [[ $replace_args == yes ]]; then
				argument=$TG_BWRAP_REPLACEMENT_FD
				replace_args=no
			elif [[ $argument == --args ]]; then
				replace_args=yes
			elif [[ $argument == --args=* ]]; then
				argument=--args=$TG_BWRAP_REPLACEMENT_FD
			fi
		fi
		if [[ $argument == -- && $inserted == no ]]; then
			forwarded+=("${TG_BWRAP_MEDIA[@]}")
			inserted=yes
		fi
		forwarded+=("$argument")
	done
	[[ $inserted == yes ]] || { printf 'Error: Flatpak sandbox command is missing.\n' >&2; return 1; }
	exec /usr/bin/bwrap "${forwarded[@]}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
