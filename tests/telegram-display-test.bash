#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./telegram-common.bash
scratch=$(mktemp -d)
wayland_pid=
wayland_input=
wayland_output=
cleanup() {
	if [[ -n ${wayland_input:-} ]]; then exec {wayland_input}>&-; fi
	if [[ -n ${wayland_output:-} ]]; then exec {wayland_output}<&-; fi
	if [[ -n ${wayland_pid:-} ]]; then wait "$wayland_pid" || :; fi
	rm -rf -- "$scratch"
}
trap cleanup EXIT
XDG_RUNTIME_DIR=$scratch/runtime
mkdir -- "$XDG_RUNTIME_DIR"
DBUS_SESSION_BUS_ADDRESS=unix:path=$scratch/session-bus
TG_PROFILE=flatpak
unset DISPLAY WAYLAND_DISPLAY WAYLAND_SOCKET
if tg_desktop_session; then exit 1; fi

has_argument() {
	local wanted=$1 argument
	for argument in "${TG_FLATPAK_ARGS[@]}"; do [[ $argument != "$wanted" ]] || return 0; done
	return 1
}
check_policy() {
	tg_policy_args
	for argument in --socket=wayland --nosocket=x11 --socket=fallback-x11 '--env=QT_QPA_PLATFORM=wayland;xcb' --unshare=ipc; do
		has_argument "$argument"
	done
	for argument in --socket=x11 --share=ipc; do
		if has_argument "$argument"; then exit 1; fi
	done
	current_policy=$(printf '%q\n' "${TG_FLATPAK_ARGS[@]}")
	[[ -z ${original_policy:-} || $current_policy == "$original_policy" ]]
	original_policy=$current_policy
}
# A normal X11 session uses the same native fallback policy as Wayland.
DISPLAY=:11
tg_desktop_session
check_policy

# A real Unix socket fixture exercises the default Wayland name without an
# exported WAYLAND_DISPLAY. Perl's core Socket module is a test dependency.
coproc TG_TEST_WAYLAND {
	perl -MSocket -e '$|=1; socket(my $listener,AF_UNIX,SOCK_STREAM,0) or die "socket: $!"; bind($listener,sockaddr_un($ARGV[0])) or die "bind: $!"; listen($listener,1) or die "listen: $!"; print "ready\n"; scalar <STDIN>;' "$XDG_RUNTIME_DIR/wayland-0"
}
wayland_pid=$TG_TEST_WAYLAND_PID
wayland_input=${TG_TEST_WAYLAND[1]}
wayland_output=${TG_TEST_WAYLAND[0]}
IFS= read -r ready <&"$wayland_output"
[[ $ready == ready ]]
unset DISPLAY
tg_desktop_session
[[ $(tg_wayland_socket) == "$XDG_RUNTIME_DIR/wayland-0" ]]
check_policy

# Flatpak defaults the Wayland name only when the variable is unset. An
# explicitly empty export requests fallback even if wayland-0 exists.
WAYLAND_DISPLAY=
if tg_desktop_session; then exit 1; fi
DISPLAY=:11
tg_desktop_session
check_policy
unset DISPLAY WAYLAND_DISPLAY

# Both exports still use native Wayland-preferred fallback; no saved choice or
# separate runner is introduced when moving between sessions.
DISPLAY=:11
WAYLAND_DISPLAY=wayland-0
tg_desktop_session
check_policy
WAYLAND_DISPLAY=$XDG_RUNTIME_DIR/wayland-0
XDG_RUNTIME_DIR=$scratch/other-runtime
tg_desktop_session
[[ $(tg_wayland_socket) == "$scratch/runtime/wayland-0" ]]
check_policy

# A stale Wayland export does not block a valid X11 session; neither stale
# exports nor a missing desktop bus can authorize a graphical launch alone.
WAYLAND_DISPLAY='missing-wayland'
DISPLAY=:11
tg_desktop_session
check_policy
unset DISPLAY
if tg_desktop_session; then exit 1; fi
WAYLAND_DISPLAY=$scratch/runtime/wayland-0
unset DBUS_SESSION_BUS_ADDRESS
if tg_desktop_session; then exit 1; fi
printf 'Telegram dynamic display policy and graphical-session checks passed.\n'
