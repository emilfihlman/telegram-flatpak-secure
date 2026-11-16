#!/usr/bin/env bash
# Resolve the configured microphone selection behind native desktop consent.
set -euo pipefail
umask 077
export LC_ALL=C

tg_microphones_host_server() {
	local server=$TG_PULSE_SOCKET
	[[ $server == /* && $server != *[[:space:]]* && -S $server && -O $server ]] || {
		printf 'Error: a local user-owned audio socket is required.\n' >&2
		return 1
	}
	printf 'unix:%s\n' "$server"
}

tg_microphones_resolve() {
	local snapshot index name
	snapshot=$("$TG_PROGRAMS/telegram-consent.bash" snapshot) || return 1
	case $snapshot in
		'no no'|'no yes') return 0 ;;
		'yes no'|'yes yes') ;;
		*) printf 'Error: invalid native microphone consent.\n' >&2; return 1 ;;
	esac
	[[ $TG_MICROPHONE_MODE != none ]] || return 0
	tg_microphones_host_server > /dev/null || return 1
	tg_microphones_discover "$TG_PULSE_SOCKET" || return 1
	for index in "${!TG_MICROPHONES_IDS[@]}"; do
		[[ ${TG_MICROPHONES_CONNECTED[index]} == yes ]] || continue
		[[ $TG_MICROPHONE_MODE == all || ${TG_MICROPHONES_SELECTED[index]} == yes ]] || continue
		name=${TG_MICROPHONES_IDS[index]}
		# Names are placed in PipeWire config as string targets. Avoid its
		# numeric aliases and reject unusual names instead of shortening them.
		[[ $name =~ ^[A-Za-z_][A-Za-z0-9_.:-]*$ && ${#name} -le 255 && $name != *.monitor ]] || continue
		printf '%s\0' "$name"
	done
}

main() {
	local sibling=${BASH_SOURCE[0]%/*}
	source "$sibling/telegram-common.bash"
	tg_paths
	tg_config_load required || { tg_error 'Invalid audio settings; run setup.'; return 1; }
	case ${1:-} in
		server) tg_microphones_host_server ;;
		resolve) tg_microphones_resolve ;;
		list) tg_microphones_discover "$TG_PULSE_SOCKET" && tg_microphones_show ;;
		*) tg_error 'Usage: telegram-microphones.bash {server|resolve|list}' ;;
	esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
