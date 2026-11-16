#!/usr/bin/env bash

tg_error() { printf 'Error: %s\n' "$*" >&2; return 1; }

# shellcheck disable=SC2034 # Shared paths are read by setup and launch helpers.
tg_paths() {
	TG_APP=org.telegram.desktop
	TG_PROGRAMS=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
	local telegram_home=${HOME:-}
	if [[ -z $telegram_home ]]; then telegram_home=$(getent passwd "$UID" | cut -d: -f6); fi
	[[ $telegram_home == /* ]] || return 1
	TG_HOME=$telegram_home
	TG_DATA=${XDG_DATA_HOME:-$telegram_home/.local/share}
	TG_CONFIG=${XDG_CONFIG_HOME:-$telegram_home/.config}/telegram-sandbox
	TG_RUNTIME=${XDG_RUNTIME_DIR:-/run/user/$UID}
	TG_INSTALL_DIR=$TG_DATA/telegram-sandbox
	TG_CONFIG_FILE=$TG_CONFIG/settings
	if [[ -r $TG_PROGRAMS/config-path ]]; then
		IFS= read -r -d '' TG_CONFIG_FILE < "$TG_PROGRAMS/config-path" || return 1
		TG_CONFIG=${TG_CONFIG_FILE%/*}
		TG_INSTALL_DIR=$TG_PROGRAMS
	fi
	[[ $TG_CONFIG_FILE == /*/telegram-sandbox/settings && $TG_RUNTIME == /* && $TG_DATA == /* ]] || return 1
	TG_DESKTOP=$TG_DATA/applications/org.telegram.desktop.desktop
	TG_LEGACY_DESKTOP=$TG_DATA/applications/telegram-secure.desktop
	TG_AUTOSTART_DIR=${XDG_CONFIG_HOME:-$telegram_home/.config}/autostart
	TG_LAUNCHER=$TG_INSTALL_DIR/telegram-run.bash
}

tg_config_defaults() {
	TG_CAMERA_MODE=none
	TG_CAMERA_KINDS=()
	TG_CAMERA_IDS=()
	TG_MICROPHONE=yes
	TG_PROFILE=flatpak
	TG_NATIVE_PROFILE=$TG_DATA/TelegramDesktop
	TG_PULSE_SOCKET=$TG_RUNTIME/pulse/native
}

tg_plain_path() { [[ $1 == /* && $1 != *[$'\001'-$'\037'$'\177']* ]]; }

tg_wayland_socket() {
	local display=${WAYLAND_DISPLAY-wayland-0}
	if [[ $display == /* ]]; then
		printf '%s\n' "$display"
	else
		printf '%s/%s\n' "${XDG_RUNTIME_DIR:-/run/user/$UID}" "$display"
	fi
}

tg_desktop_session() {
	[[ -n ${DBUS_SESSION_BUS_ADDRESS:-} && ( -n ${DISPLAY:-} || -S $(tg_wayland_socket) ) ]]
}

tg_config_load() {
	# shellcheck source=telegram-media.bash
	source "$TG_PROGRAMS/telegram-media.bash"
	tg_config_defaults
	if [[ ! -e $TG_CONFIG_FILE ]]; then [[ ${1:-new} != required ]]; return; fi
	[[ -f $TG_CONFIG_FILE && ! -L $TG_CONFIG_FILE ]] || return 1
	local key first second extra
	local -A seen=()
	while IFS=$'\t' read -r key first second extra || [[ -n $key ]]; do
		[[ -n $key && $key != \#* ]] || continue
		[[ -z $extra ]] || return 1
		if [[ $key != camera ]]; then
			[[ ! ${seen[$key]+set} && -z $second ]] || return 1
			seen[$key]=1
		fi
		case $key in
			camera-mode) [[ $first == all || $first == selected || $first == none ]] || return 1; TG_CAMERA_MODE=$first ;;
			microphone) [[ $first == yes || $first == no ]] || return 1; TG_MICROPHONE=$first ;;
			profile) [[ $first == flatpak || $first == native ]] || return 1; TG_PROFILE=$first ;;
			native-profile) tg_plain_path "$first" || return 1; TG_NATIVE_PROFILE=$first ;;
			runtime) tg_plain_path "$first" || return 1; TG_RUNTIME=$first ;;
			pulse-socket) tg_plain_path "$first" || return 1; TG_PULSE_SOCKET=$first ;;
			camera)
				tg_media_valid_camera "$first" "$second" || return 1
				TG_CAMERA_KINDS+=("$first"); TG_CAMERA_IDS+=("$second") ;;
			*) return 1 ;;
		esac
	done < "$TG_CONFIG_FILE"
	for key in camera-mode microphone profile native-profile runtime pulse-socket; do
		[[ ${seen[$key]+set} ]] || return 1
	done
}

tg_config_save() (
	local temporary index
	tg_plain_path "$TG_NATIVE_PROFILE" && tg_plain_path "$TG_RUNTIME" && tg_plain_path "$TG_PULSE_SOCKET" || return 1
	mkdir -p -- "$TG_CONFIG" || return 1
	temporary=$(mktemp "$TG_CONFIG/.telegram-settings.XXXXXX") || return 1
	trap 'rm -f -- "$temporary"' EXIT
	{
		printf 'camera-mode\t%s\nmicrophone\t%s\nprofile\t%s\n' "$TG_CAMERA_MODE" "$TG_MICROPHONE" "$TG_PROFILE"
		printf 'native-profile\t%s\nruntime\t%s\npulse-socket\t%s\n' "$TG_NATIVE_PROFILE" "$TG_RUNTIME" "$TG_PULSE_SOCKET"
		for index in "${!TG_CAMERA_IDS[@]}"; do
			printf 'camera\t%s\t%s\n' "${TG_CAMERA_KINDS[index]}" "${TG_CAMERA_IDS[index]}"
		done
	} > "$temporary" || return 1
	if cmp -s -- "$temporary" "$TG_CONFIG_FILE"; then return 0; fi
	chmod 600 -- "$temporary" && mv -fT -- "$temporary" "$TG_CONFIG_FILE"
)

# shellcheck disable=SC2034 # Both arrays are the public result used by the launcher.
tg_policy_args() {
	TG_FLATPAK_ARGS=(
		--nofilesystem=host:reset '--filesystem=xdg-download/Telegram Desktop:create'
		--unshare=ipc --share=network --socket=wayland --nosocket=x11 --socket=fallback-x11
		--nosocket=pulseaudio --nosocket=session-bus --nosocket=system-bus
		--nosocket=ssh-auth --nosocket=gpg-agent --nosocket=pcsc --nosocket=cups
		--nodevice=all --nodevice=usb --nodevice=input --nodevice=kvm --nodevice=shm --device=dri --nousb=all
		--disallow=devel --disallow=bluetooth --disallow=canbus
		'--env=QT_QPA_PLATFORM=wayland;xcb' --unset-env=QT_PLUGIN_PATH
	)
	TG_PROFILE_ARGS=()
	if [[ $TG_PROFILE == native ]]; then
		[[ -d $TG_NATIVE_PROFILE/tdata ]] || { tg_error 'The selected Telegram profile is missing. Run ./telegram-setup.bash.'; return 1; }
		TG_FLATPAK_ARGS+=("--filesystem=$TG_NATIVE_PROFILE")
		TG_PROFILE_ARGS=(-workdir "$TG_NATIVE_PROFILE")
	fi
}

tg_install_file() (
	local source=$1 target=$2 mode=$3 temporary
	[[ ! -d $target ]] || return 1
	if [[ ! -L $target ]] && cmp -s -- "$source" "$target" && [[ $(stat -c '%a' -- "$target") == "$mode" ]]; then return 0; fi
	mkdir -p -- "${target%/*}" || return 1
	temporary=$(mktemp "${target%/*}/.telegram-install.XXXXXX") || return 1
	trap 'rm -f -- "$temporary"' EXIT
	install -m "$mode" -- "$source" "$temporary" && mv -fT -- "$temporary" "$target"
)

tg_remote_check() {
	local remote remote_url remote_options
	remote=$(flatpak remotes --user --show-disabled --columns=name,url,options) || return 1
	remote=$(awk -F '\t' '$1 == "flathub" { print $2 "\t" $3 }' <<< "$remote")
	IFS=$'\t' read -r remote_url remote_options <<< "$remote"
	[[ ${remote_url%/} == https://dl.flathub.org/repo && $remote_options != *disabled* && $remote_options != *no-gpg-verify* ]] || {
		tg_error 'Your Flathub remote has an unexpected address or signature configuration.'; return 1;
	}
}

tg_origin_check() {
	tg_remote_check || return 1
	local origin
	origin=$(flatpak info --user --show-origin "$TG_APP" stable) || return 1
	[[ $origin == flathub ]] || tg_error 'The installed user/stable Telegram is not from Flathub.'
}

tg_dependencies() {
	local package state desktop=${XDG_CURRENT_DESKTOP:-}
	local -a packages=(flatpak bubblewrap xdg-desktop-portal pulseaudio-utils util-linux xdg-utils desktop-file-utils procps) missing=()
	case :${desktop^^}: in
		*:GNOME:*) packages+=(xdg-desktop-portal-gnome) ;;
		*:KDE:*) packages+=(xdg-desktop-portal-kde) ;;
		*) packages+=(xdg-desktop-portal-gtk) ;;
	esac
	if [[ $TG_MICROPHONE == no ]] && ! command -v pulseaudio >/dev/null; then packages+=(pipewire-bin libpipewire-0.3-modules); fi
	for package in "${packages[@]}"; do
		state=$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null) || state=
		[[ $state == 'install ok installed' ]] || missing+=("$package")
	done
	if (( ${#missing[@]} )); then
		printf 'Installing required packages: %s\n' "${missing[*]}"
		sudo apt-get update && sudo apt-get install --no-install-recommends -y -- "${missing[@]}" || return 1
	fi
}

tg_stop() {
	local rows app instance pid pidfile
	rows=$(flatpak ps --columns=application,instance,pid) || return 1
	while IFS=$'\t' read -r app instance pid; do
		[[ $app == "$TG_APP" && $instance =~ ^[0-9]+$ ]] || continue
		# Ask the identified app to quit, then use Flatpak's instance handle if needed.
		local -a args=()
		[[ $TG_PROFILE != native ]] || args=(-workdir "$TG_NATIVE_PROFILE")
		timeout 5s flatpak enter "$instance" /app/bin/Telegram "${args[@]}" -quit >/dev/null 2>&1 || :
		if [[ $pid =~ ^[0-9]+$ ]] && command -v pidwait >/dev/null; then
			pidfile=$(mktemp "$TG_RUNTIME/telegram-stop.XXXXXX") || return 1
			if printf '%s\n' "$pid" > "$pidfile" && timeout 5s pidwait -F "$pidfile"; then
				rm -- "$pidfile"; continue
			fi
			rm -- "$pidfile"
		fi
		flatpak kill "$instance" 2>/dev/null || :
	done <<< "$rows"
}

tg_remove_files() {
	local file
	# These are this wrapper's files, never Telegram profiles or downloads.
	tg_desktop_remove || return 1
	for file in telegram-run.bash telegram-bwrap.bash telegram-common.bash telegram-media.bash telegram-audio.bash config-path; do
		[[ ! -f $TG_INSTALL_DIR/$file && ! -L $TG_INSTALL_DIR/$file ]] || rm -- "$TG_INSTALL_DIR/$file" || return 1
	done
	if [[ -e $TG_CONFIG_FILE || -L $TG_CONFIG_FILE ]]; then rm -- "$TG_CONFIG_FILE" || return 1; fi
	rmdir -- "$TG_INSTALL_DIR" "$TG_CONFIG" 2>/dev/null || :
}

tg_remove() {
	if command -v flatpak >/dev/null; then
		tg_stop || return 1
		flatpak permission-remove devices camera "$TG_APP" 2>/dev/null || :
	fi
	tg_remove_files || return 1
	printf 'Telegram wrapper removed.\n'
}
