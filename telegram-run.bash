#!/usr/bin/bash
set -euo pipefail
umask 077

main() {
	local sibling=${BASH_SOURCE[0]%/*}
	(( EUID != 0 )) || { printf 'Run Telegram as your desktop user, without sudo.\n' >&2; return 1; }
	source "$sibling/telegram-common.bash"
	tg_paths
	tg_config_load required || { tg_error 'Run ./telegram-setup.bash to configure Telegram.'; return 1; }
	tg_desktop_session || {
		printf 'Launch Telegram from your graphical desktop session.\n' >&2
		return 1
	}
	tg_policy_args
	tg_consent_snapshot
	export FLATPAK_BWRAP="$TG_PROGRAMS/telegram-bwrap.bash"
	export FLATPAK_DBUSPROXY="$TG_PROGRAMS/telegram-dbus-proxy.bash"
	TG_FLATPAK_ARGS+=(--env=TELEGRAM_WRAPPER=telegram-sandbox
		"--env=TELEGRAM_MICROPHONE_CONSENT=${TG_NATIVE_CONSENT%% *}"
		"--env=TELEGRAM_CAMERA_CONSENT=${TG_NATIVE_CONSENT#* }")
	exec "$TG_PROGRAMS/telegram-consent.bash" --run "$TG_NATIVE_CONSENT" -- \
		/usr/bin/flatpak run --user --branch=stable --die-with-parent "${TG_FLATPAK_ARGS[@]}" \
		--file-forwarding "$TG_APP" "${TG_PROFILE_ARGS[@]}" "$@"
}

main "$@"
