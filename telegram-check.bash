#!/usr/bin/env bash
# Sourced by setup; the live probe does not start or interrupt Telegram.

tg_check_probe() (
	local host_socket socket_id settings_id wayland_socket wayland_available=no probe
	# Use the installed launcher's policy and hook, including its saved paths.
	# shellcheck source=telegram-common.bash
	source "$TG_INSTALL_DIR/telegram-common.bash"
	tg_paths && tg_config_load required && tg_policy_args || return 1
	export FLATPAK_BWRAP="$TG_PROGRAMS/telegram-bwrap.bash"
	unset FLATPAK_DBUSPROXY
	TG_FLATPAK_ARGS+=(--env=TELEGRAM_WRAPPER=telegram-sandbox)
	host_socket=$TG_PULSE_SOCKET
	settings_id=$(stat -Lc '%d:%i' -- "$TG_CONFIG_FILE") || return 1
	wayland_socket=$(tg_wayland_socket) || return 1
	# Flatpak may supply a per-app Wayland proxy, so socket identity can differ.
	[[ ! -S $wayland_socket ]] || wayland_available=yes
	if [[ $TG_MICROPHONE == no ]]; then
		# shellcheck source=telegram-audio.bash
		source "$TG_PROGRAMS/telegram-audio.bash"
		trap 'tg_audio_stop' EXIT
		trap 'exit 129' HUP
		trap 'exit 130' INT
		trap 'exit 143' TERM
		tg_audio_start || return 1
		TG_FLATPAK_ARGS+=("--env=TELEGRAM_PULSE_SOCKET=$TG_AUDIO_SOCKET")
		socket_id=$(stat -Lc '%d:%i' -- "$TG_AUDIO_SOCKET") || return 1
	else
		socket_id=$(stat -Lc '%d:%i' -- "$TG_PULSE_SOCKET") || return 1
	fi
	tg_media_resolve || return 1
	probe=$(cat <<'PROBE'
set -eu
fail() { printf 'CHECK   %s\n' "$*" >&2; exit 1; }
settings=$1
host_socket=$2
socket_id=$3
settings_id=$4
wayland_available=$5
shift 5
[ "${TELEGRAM_WRAPPER:-}" = telegram-sandbox ] || fail 'Wrapper marker is missing.'
[ "${QT_QPA_PLATFORM:-}" = 'wayland;xcb' ] || fail 'Unexpected Qt display selection.'
[ "${PULSE_SERVER:-}" = unix:/run/flatpak/pulse/native ] || fail 'Unexpected audio endpoint.'
[ -S /run/flatpak/pulse/native ] || fail 'Approved audio socket is missing.'
[ "$(stat -Lc '%d:%i' /run/flatpak/pulse/native)" = "$socket_id" ] || fail 'Audio socket does not match the approved endpoint.'
if [ -e "$settings" ]; then
	[ "$(stat -Lc '%d:%i' -- "$settings")" != "$settings_id" ] || fail 'Wrapper settings are exposed inside the sandbox.'
fi
if [ "$host_socket" != /run/flatpak/pulse/native ]; then
	[ ! -S "$host_socket" ] || fail 'Desktop audio socket is directly exposed.'
fi
for path in /dev/snd /dev/input /dev/bus/usb /dev/kvm "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pipewire-0"; do
	[ ! -e "$path" ] || fail "Unexpected direct device/audio access: $path"
done
for node do
	[ -c "$node" ] || fail "Selected camera is unavailable inside the sandbox: $node"
done
for node in /dev/video*; do
	[ -e "$node" ] || continue
	allowed=no
	for selected do [ "$node" != "$selected" ] || allowed=yes; done
	[ "$allowed" = yes ] || fail "Unselected camera is exposed: $node"
done
wayland_socket=${WAYLAND_DISPLAY-wayland-0}
case $wayland_socket in
	/*) ;;
	*) wayland_socket=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$wayland_socket ;;
esac
if [ "$wayland_available" = yes ]; then
	[ -S "$wayland_socket" ] || fail 'The available Wayland socket is missing.'
	[ -z "${DISPLAY:-}" ] || fail 'X11 display access is enabled while Wayland is available.'
	for path in /tmp/.X11-unix/X*; do
		[ ! -S "$path" ] || fail 'An X11 socket is exposed while Wayland is available.'
	done
	display_backend=Wayland
else
	[ "$wayland_available" = no ] || fail 'Unexpected display availability check.'
	[ ! -S "$wayland_socket" ] || fail 'An unexpected Wayland socket is exposed.'
	[ -n "${DISPLAY:-}" ] || fail 'No usable display was passed to the sandbox.'
	if [ -n "${XAUTHORITY:-}" ]; then
		[ -r "$XAUTHORITY" ] || fail 'The X11 authorization file is unavailable.'
	fi
	display_number=
	case $DISPLAY in
		:*) display_number=${DISPLAY#:} ;;
		unix:*) display_number=${DISPLAY#unix:} ;;
		unix/:*) display_number=${DISPLAY#unix/:} ;;
	esac
	if [ -n "$display_number" ]; then
		display_number=${display_number%%.*}
		case $display_number in ''|*[!0-9]*) fail 'Unexpected local X11 display.' ;; esac
		[ -S "/tmp/.X11-unix/X$display_number" ] || fail 'The selected X11 socket is unavailable.'
	fi
	display_backend=X11
fi
section=
sockets=
while IFS= read -r line || [ -n "$line" ]; do
	case $line in
		\[*\]) section=$line ;;
		sockets=*)
			[ "$section" = '[Context]' ] || continue
			sockets=${line#sockets=}
			# Native fallback metadata can retain x11 even when it is not mounted.
			case $sockets in
				'wayland;fallback-x11;'|'fallback-x11;wayland;'|'x11;wayland;fallback-x11;') ;;
				*) fail "Unexpected display/socket permissions: $sockets" ;;
			esac ;;
		devices=*)
			[ "$section" = '[Context]' ] || continue
			case ${line#devices=} in ''|'dri;') ;; *) fail 'Broad device permissions are enabled.' ;; esac ;;
		shared=*)
			[ "$section" = '[Context]' ] || continue
			case ${line#shared=} in ''|'network;') ;; *) fail 'Unexpected shared IPC permissions.' ;; esac ;;
	esac
done < /.flatpak-info
[ -n "$sockets" ] || fail 'Display policy was not found.'
printf 'OK      Native %s sandbox/media probe: selected cameras, approved audio, no raw audio devices.\n' "$display_backend"
PROBE
	)
	# A stuck diagnostic must not leave its sandbox or private broker running.
	timeout --kill-after=5s 60s /usr/bin/flatpak run --user --branch=stable --die-with-parent "${TG_FLATPAK_ARGS[@]}" \
		--command=sh "$TG_APP" -c "$probe" telegram-check \
		"$TG_CONFIG_FILE" "$host_socket" "$socket_id" "$settings_id" "$wayland_available" "${TG_CAMERA_NODES[@]}"
)

tg_check_unsafe_grants() {
	local section='' line name namespace grant
	TG_CHECK_UNSAFE=()
	while IFS= read -r line || [[ -n $line ]]; do
		case $line in
			\[*\]) section=$line ;;
			*=*)
				[[ $section == '[Session Bus Policy]' ]] || continue
				name=${line%%=*}
				grant=${line#*=}
				[[ $grant == talk || $grant == own ]] || continue
				namespace=
				[[ $name != *'.*' ]] || namespace=${name%'.*'}
				# shellcheck disable=SC2053 # Compare native D-Bus namespace patterns.
				if [[ org.freedesktop.Flatpak == $name || org.freedesktop.systemd1 == $name ||
					org.freedesktop.Flatpak == "$namespace" || org.freedesktop.systemd1 == "$namespace" ]]; then
					TG_CHECK_UNSAFE+=("$line")
				fi ;;
		esac
	done
}

tg_check_repair_user_overrides() {
	local overrides line answer
	# This native command reads this user's per-app overrides only. Never reset
	# global or system permissions while repairing one wrapper installation.
	overrides=$(flatpak override --user --show "$TG_APP") || return 1
	tg_check_unsafe_grants <<< "$overrides"
	(( ${#TG_CHECK_UNSAFE[@]} )) || return 0
	printf '\nPossible host-control grants in Telegram-specific user permission overrides:\n'
	for line in "${TG_CHECK_UNSAFE[@]}"; do printf '  %q\n' "$line"; done
	printf 'Raw override entries may be superseded by stronger permission rules.\n'
	printf "Resetting clears this user's Telegram-specific Flatpak permission overrides. Account data is retained.\n"
	read -r -p 'Reset these Telegram permission overrides? [y/N]: ' answer || return 1
	case ${answer,,} in
		y|yes) flatpak override --user --reset "$TG_APP" ;;
		*) printf 'Telegram permission overrides were retained.\n'; return 1 ;;
	esac
}

tg_check_diagnose_overrides() {
	local scope overrides line
	local -a arguments=()
	for scope in user-app user-global system-app system-global; do
		case $scope in
			user-app) arguments=(override --user --show "$TG_APP") ;;
			user-global) arguments=(override --user --show) ;;
			system-app) arguments=(override --system --show "$TG_APP") ;;
			system-global) arguments=(override --system --show) ;;
		esac
		if ! overrides=$(flatpak "${arguments[@]}"); then
			printf 'CHECK   Could not inspect %s Flatpak overrides.\n' "$scope"
			continue
		fi
		tg_check_unsafe_grants <<< "$overrides"
		(( ${#TG_CHECK_UNSAFE[@]} )) || continue
		printf 'POSSIBLE Host-control entries in raw %s Flatpak overrides:\n' "$scope"
		for line in "${TG_CHECK_UNSAFE[@]}"; do printf '  %q\n' "$line"; done
		printf '  These entries may be superseded by stronger permission rules.\n'
		printf '  Inspect: flatpak'; printf ' %q' "${arguments[@]}"; printf '\n'
		if [[ $scope == user-app ]]; then
			printf '  Check/repair can reset these Telegram-specific user overrides after confirmation.\n'
		else
			printf '  Review the effective permissions from the failed probe before changing this scope.\n'
			printf '  The wrapper does not reset global or system overrides.\n'
		fi
	done
	return 0
}

tg_check_camera_portal() {
	local rows table object application permission _data expected=no count=0 actual='missing'
	[[ $TG_CAMERA_MODE != all ]] || expected=yes
	if ! rows=$(flatpak permission-show "$TG_APP"); then
		printf 'CHECK   Could not read the camera portal permission.\n'
		return 1
	fi
	while IFS=$'\t' read -r table object application permission _data; do
		[[ $table == devices && $object == camera && $application == "$TG_APP" ]] || continue
		count=$((count + 1))
		actual=$permission
	done <<< "$rows"
	if (( count != 1 )) || [[ $actual != "$expected" ]]; then
		printf 'CHECK   Camera portal permission is %s; camera mode %s requires %s. Update/configure repairs it.\n' "$actual" "$TG_CAMERA_MODE" "$expected"
		return 1
	fi
	printf 'OK      Camera portal permission matches camera mode %s.\n' "$TG_CAMERA_MODE"
}

tg_check() (
	local file failed=0 ready=yes
	printf '\nChecking Telegram setup...\n'
	if tg_origin_check; then
		printf 'OK      Installed Telegram is from the configured signed Flathub remote.\n'
	else
		printf 'CHECK   Telegram installation or Flathub origin needs repair.\n'
		failed=1
		ready=no
	fi
	for file in telegram-run.bash telegram-common.bash telegram-media.bash telegram-audio.bash telegram-bwrap.bash; do
		if [[ ! -x $TG_INSTALL_DIR/$file ]]; then
			printf 'CHECK   Missing installed helper: %s\n' "$file"
			failed=1
			ready=no
		fi
	done
	if [[ ! -r $TG_INSTALL_DIR/config-path ]] || ! tg_config_load required; then
		printf 'CHECK   Saved wrapper settings are missing or invalid.\n'
		failed=1
		ready=no
	else
		printf 'OK      Installed wrapper and saved settings are present.\n'
	fi
	if tg_desktop_check; then
		printf 'OK      Menu, tg: links and configured autostart use the wrapper.\n'
	else
		failed=1
	fi
	if [[ $ready == yes ]]; then
		if ! tg_check_camera_portal; then failed=1; fi
		if ! tg_check_probe; then
			printf 'CHECK   Native sandbox/media probe failed.\n'
			failed=1
			tg_check_diagnose_overrides
		fi
	fi
	if (( failed )); then
		printf 'Update/configure repairs wrapper files and settings. External Flatpak overrides are not changed automatically.\n'
		return 1
	fi
	printf 'Telegram setup checks passed.\n'
)
