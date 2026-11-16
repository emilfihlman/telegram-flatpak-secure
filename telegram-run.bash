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
	export FLATPAK_BWRAP="$TG_PROGRAMS/telegram-bwrap.bash"
	unset FLATPAK_DBUSPROXY
	TG_FLATPAK_ARGS+=(--env=TELEGRAM_WRAPPER=telegram-sandbox)
	exec /usr/bin/flatpak run --user --branch=stable "${TG_FLATPAK_ARGS[@]}" \
		--file-forwarding "$TG_APP" "${TG_PROFILE_ARGS[@]}" "$@"
}

main "$@"
