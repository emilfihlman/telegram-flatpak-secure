#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./telegram-common.bash
source ./telegram-desktop.bash
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
TG_DATA=$scratch/data
TG_DESKTOP=$TG_DATA/applications/org.telegram.desktop.desktop
TG_LEGACY_DESKTOP=$TG_DATA/applications/telegram-secure.desktop
TG_AUTOSTART_DIR=$scratch/config/autostart
# Exercise native Desktop Entry escaping, including shell and field-code chars.
# shellcheck disable=SC2016 # These characters belong to the literal test path.
TG_LAUNCHER=$scratch/'launcher=space %$`"\'/telegram-run.bash
export XDG_DATA_HOME=$TG_DATA XDG_DATA_DIRS=$scratch/system-data
export XDG_CONFIG_HOME=$scratch/config XDG_CONFIG_DIRS=$scratch/system-config
export XDG_CURRENT_DESKTOP=X-Generic DE=generic DESKTOP_SESSION=generic
mkdir -p -- "${TG_DESKTOP%/*}" "$TG_AUTOSTART_DIR" "${TG_LAUNCHER%/*}" \
	"$XDG_CONFIG_DIRS/autostart" "$XDG_DATA_DIRS/applications"

# An existing unrelated launcher requires approval before any installation.
printf '[Desktop Entry]\nType=Application\nName=Existing\nExec=/usr/bin/true\n' > "$TG_DESKTOP"
cp -- "$TG_DESKTOP" "$scratch/original.desktop"
if tg_desktop_prepare "$scratch/declined" <<< no > /dev/null 2>&1; then exit 1; fi
cmp -- "$TG_DESKTOP" "$scratch/original.desktop"

# Preserve autostart's disabled/desktop conditions, routing only Telegram entries.
cat > "$TG_AUTOSTART_DIR/org.telegram.desktop._abc123.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Telegram
Exec=/usr/bin/flatpak run org.telegram.desktop -autostart
Hidden=true
X-GNOME-Autostart-enabled=false
OnlyShowIn=GNOME;
Actions=quit;
[Desktop Action quit]
Name=Quit
Exec=/app/bin/Telegram -quit
EOF
cat > "$TG_AUTOSTART_DIR/unrelated.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Unrelated
Exec=/usr/bin/echo /some/telegram
EOF
cp -- "$TG_AUTOSTART_DIR/unrelated.desktop" "$scratch/unrelated.desktop"
cp -- "$scratch/unrelated.desktop" "${TG_DESKTOP%/*}/unrelated.desktop"
cp -- "$scratch/unrelated.desktop" "${TG_DESKTOP%/*}/telegram.desktop"
cat > "$XDG_DATA_DIRS/applications/telegram-desktop.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=System Telegram
Exec=/usr/bin/telegram-desktop %u
EOF
cp -- "$XDG_DATA_DIRS/applications/telegram-desktop.desktop" "$scratch/system-menu.desktop"
# User entries win by basename, even over a conflicting system autostart.
cp -- "$XDG_DATA_DIRS/applications/telegram-desktop.desktop" "$XDG_CONFIG_DIRS/autostart/unrelated.desktop"
cp -- "$XDG_DATA_DIRS/applications/telegram-desktop.desktop" "$XDG_CONFIG_DIRS/autostart/org.telegram.desktop._abc123.desktop"
cat > "$XDG_CONFIG_DIRS/autostart/telegram.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=System Telegram
Exec=/usr/bin/telegram-desktop -autostart
OnlyShowIn=KDE;
EOF
cp -- "$XDG_CONFIG_DIRS/autostart/telegram.desktop" "$scratch/system-autostart.desktop"
cat > "$TG_AUTOSTART_DIR/personal-name.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Telegram
Exec=/opt/Telegram/Telegram -autostart
EOF
tg_desktop_prepare "$scratch/approved" > /dev/null <<'ANSWERS'
yes
yes
yes
yes
ANSWERS
cmp -- "$TG_DESKTOP" "$scratch/original.desktop"
[[ ! -e $scratch/approved/desktop/autostart/unrelated.desktop ]]
[[ -f $scratch/approved/desktop/autostart/telegram.desktop ]]
grep -Fxq 'OnlyShowIn=KDE;' "$scratch/approved/desktop/autostart/telegram.desktop"
grep -Fxq 'NoDisplay=true' "$scratch/approved/desktop/aliases/telegram.desktop"
grep -Fxq 'NoDisplay=true' "$scratch/approved/desktop/aliases/telegram-desktop.desktop"
grep -Fxq 'Hidden=true' "$scratch/approved/desktop/autostart/org.telegram.desktop._abc123.desktop"
grep -Fxq 'X-GNOME-Autostart-enabled=false' "$scratch/approved/desktop/autostart/org.telegram.desktop._abc123.desktop"
grep -Fxq 'OnlyShowIn=GNOME;' "$scratch/approved/desktop/autostart/org.telegram.desktop._abc123.desktop"
if grep -q '^\[Desktop Action ' "$scratch/approved/desktop/autostart/org.telegram.desktop._abc123.desktop"; then exit 1; fi

# A real GIO launch must parse the unusual executable path and URI correctly.
cat > "$TG_LAUNCHER" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$TG_DESKTOP_TEST_RECEIPT"
EOF
chmod +x -- "$TG_LAUNCHER"
export TG_DESKTOP_TEST_RECEIPT=$scratch/launched
tg_desktop_apply "$scratch/approved"
desktop-file-validate "$TG_DESKTOP"
tg_desktop_check
cmp -- "$XDG_DATA_DIRS/applications/telegram-desktop.desktop" "$scratch/system-menu.desktop"
cmp -- "$XDG_CONFIG_DIRS/autostart/telegram.desktop" "$scratch/system-autostart.desktop"
mkfifo -- "$TG_DESKTOP_TEST_RECEIPT"
exec {receipt_fd}<> "$TG_DESKTOP_TEST_RECEIPT"
gio launch "$TG_DESKTOP" 'tg://resolve?domain=test'
received=()
for index in 0 1 2 3; do
	IFS= read -r -d '' -t 10 -u "$receipt_fd" "received[$index]"
done
exec {receipt_fd}>&-
[[ ${#received[@]} == 4 && ${received[0]} == -- && ${received[1]} == @@u &&
	${received[2]} == 'tg://resolve?domain=test' && ${received[3]} == @@ ]]
rm -- "$TG_DESKTOP_TEST_RECEIPT"

# Repeat setup needs no replacement approvals, and a broken handler is detected.
tg_desktop_prepare "$scratch/repeated" < /dev/null
tg_desktop_apply "$scratch/repeated"
tg_desktop_check
xdg-mime default unrelated.desktop x-scheme-handler/tg
if tg_desktop_check > /dev/null; then exit 1; fi
tg_desktop_apply "$scratch/repeated"

# Removal keeps unrelated entries and does not alter unrelated MIME defaults.
xdg-mime default unrelated.desktop text/plain
tg_desktop_remove
[[ ! -e $TG_DESKTOP && ! -e $TG_AUTOSTART_DIR/org.telegram.desktop._abc123.desktop &&
	! -e $TG_AUTOSTART_DIR/personal-name.desktop && ! -e $TG_AUTOSTART_DIR/telegram.desktop &&
	! -e ${TG_DESKTOP%/*}/telegram.desktop && ! -e ${TG_DESKTOP%/*}/telegram-desktop.desktop ]]
cmp -- "$TG_AUTOSTART_DIR/unrelated.desktop" "$scratch/unrelated.desktop"
cmp -- "$XDG_DATA_DIRS/applications/telegram-desktop.desktop" "$scratch/system-menu.desktop"
cmp -- "$XDG_CONFIG_DIRS/autostart/telegram.desktop" "$scratch/system-autostart.desktop"
[[ $(xdg-mime query default text/plain) == unrelated.desktop ]]
printf 'Telegram menu, URI routing, autostart and removal checks passed.\n'
