#!/usr/bin/bash
set -euo pipefail
umask 077

main() {
	local sibling=${BASH_SOURCE[0]%/*} finished status=0 flatpak_pid
	(( EUID != 0 )) || { printf 'Run Telegram as your desktop user, without sudo.\n' >&2; return 1; }
	source "$sibling/telegram-common.bash"
	tg_paths
	tg_config_load required || { tg_error 'Run ./telegram-setup.bash to configure Telegram.'; return 1; }
	[[ -n ${WAYLAND_DISPLAY:-} && -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] || {
		printf 'Launch Telegram from your Wayland desktop session.\n' >&2
		return 1
	}
	tg_policy_args
	export FLATPAK_BWRAP="$TG_PROGRAMS/telegram-bwrap.bash"
	unset FLATPAK_DBUSPROXY
	TG_FLATPAK_ARGS+=(--env=TELEGRAM_WRAPPER=telegram-sandbox)
	if [[ $TG_MICROPHONE == yes ]]; then
		exec /usr/bin/flatpak run --user --branch=stable "${TG_FLATPAK_ARGS[@]}" \
			--file-forwarding "$TG_APP" "${TG_PROFILE_ARGS[@]}" "$@"
	fi
	source "$sibling/telegram-audio.bash"
	trap 'tg_audio_stop' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	tg_audio_start
	TG_FLATPAK_ARGS+=("--env=TELEGRAM_PULSE_SOCKET=$TG_AUDIO_SOCKET")
	/usr/bin/flatpak run --user --branch=stable --die-with-parent "${TG_FLATPAK_ARGS[@]}" \
		--file-forwarding "$TG_APP" "${TG_PROFILE_ARGS[@]}" "$@" &
	flatpak_pid=$!
	# Block on actual child completion. The private audio server lasts for this
	# launcher; Flatpak's native parent-death handling owns sandbox cleanup.
	wait -n -p finished "$flatpak_pid" "$TG_AUDIO_PID" || status=$?
	if [[ $finished == "$TG_AUDIO_PID" ]]; then
		TG_AUDIO_PID=
		printf 'Error: Telegram audio stopped unexpectedly.\n' >&2
		return 1
	fi
	return "$status"
}

main "$@"
