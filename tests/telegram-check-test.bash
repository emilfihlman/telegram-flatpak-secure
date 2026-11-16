#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./telegram-common.bash
source ./telegram-check.bash
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
TG_PROGRAMS=$PWD
TG_APP=org.telegram.desktop
TG_DATA=$scratch/data
TG_INSTALL_DIR=$TG_DATA/telegram-sandbox
TG_CONFIG=$scratch/config/telegram-sandbox
TG_CONFIG_FILE=$TG_CONFIG/settings
TG_RUNTIME=$scratch/runtime
mkdir -p -- "$TG_INSTALL_DIR" "$TG_RUNTIME"
for file in telegram-run.bash telegram-common.bash telegram-media.bash telegram-audio.bash telegram-bwrap.bash \
	telegram-consent.bash telegram-dbus-proxy.bash telegram-audio-broker.bash telegram-microphones.bash; do
	install -m 755 -- "$file" "$TG_INSTALL_DIR/$file"
done
printf '%s\0' "$TG_CONFIG_FILE" > "$TG_INSTALL_DIR/config-path"
tg_config_defaults
tg_config_save
printf 'devices\tcamera\t%s\tno\t0x00\n' "$TG_APP" > "$scratch/portal"
: > "$scratch/overrides"
: > "$scratch/user-global"
: > "$scratch/system-app"
: > "$scratch/system-global"
# Exercise the real native consent parser with a private fixture store.
mkdir -- "$scratch/bin"
cat > "$scratch/bin/flatpak" <<'NATIVE_FLATPAK'
#!/usr/bin/env bash
[[ $* == 'permission-show org.telegram.desktop' ]] || exit 90
cat -- "$TG_TEST_NATIVE_ROWS"
NATIVE_FLATPAK
printf '#!/usr/bin/env bash\nexit 0\n' > "$scratch/bin/gsettings"
printf '#!/usr/bin/env bash\nexit 0\n' > "$scratch/bin/busctl"
chmod 755 -- "$scratch/bin/flatpak" "$scratch/bin/gsettings" "$scratch/bin/busctl"
export TG_TEST_NATIVE_ROWS=$scratch/portal
export PATH=$scratch/bin:$PATH
flatpak() {
	case $* in
		'permission-show org.telegram.desktop') cat "$scratch/portal" ;;
		'override --user --show org.telegram.desktop') cat "$scratch/overrides" ;;
		'override --user --show') cat "$scratch/user-global" ;;
		'override --system --show org.telegram.desktop') cat "$scratch/system-app" ;;
		'override --system --show') cat "$scratch/system-global" ;;
		'override --user --reset org.telegram.desktop') printf 'reset\n' >> "$scratch/resets" ;;
		*) return 90 ;;
	esac
}
tg_origin_check() { [[ ! -e $scratch/bad-origin ]]; }
tg_desktop_check() { [[ ! -e $scratch/bad-desktop ]]; }
# The integration check uses the real native sandbox. These fixtures establish
# that missing/untrusted installation state cannot be reported as a live pass.
tg_check_probe() { printf 'probe\n' >> "$scratch/probes"; [[ ! -e $scratch/bad-probe ]]; }
tg_check > "$scratch/result"
[[ $(wc -l < "$scratch/probes") == 1 ]]
grep -q 'checks passed' "$scratch/result"
: > "$scratch/bad-origin"
if tg_check > "$scratch/result"; then exit 1; fi
[[ $(wc -l < "$scratch/probes") == 1 ]]
grep -q 'origin needs repair' "$scratch/result"
rm -- "$scratch/bad-origin"
printf 'camera-mode\tnone\n' > "$TG_CONFIG_FILE"
if tg_check > "$scratch/result"; then exit 1; fi
[[ $(wc -l < "$scratch/probes") == 1 ]]
grep -q 'settings are missing or invalid' "$scratch/result"
tg_config_defaults
tg_config_save
rm -- "$TG_INSTALL_DIR/telegram-bwrap.bash"
if tg_check > "$scratch/result"; then exit 1; fi
[[ $(wc -l < "$scratch/probes") == 1 ]]
install -m 755 telegram-bwrap.bash "$TG_INSTALL_DIR/telegram-bwrap.bash"
: > "$scratch/bad-desktop"
if tg_check > "$scratch/result"; then exit 1; fi
[[ $(wc -l < "$scratch/probes") == 2 ]]
rm -- "$scratch/bad-desktop"
: > "$scratch/bad-probe"
if tg_check > "$scratch/result"; then exit 1; fi
grep -q 'probe failed' "$scratch/result"
if grep -q 'checks passed' "$scratch/result"; then exit 1; fi

# Repair resets only a proven unsafe user/app override, after explicit consent.
printf '[Session Bus Policy]\norg.freedesktop.Notifications=talk\n' > "$scratch/overrides"
tg_check_repair_user_overrides < /dev/null
[[ ! -e $scratch/resets ]]
for grant in 'org.freedesktop.Flatpak=talk' 'org.freedesktop.Flatpak.*=talk' 'org.freedesktop.*=own' '*=talk' 'ca.desrt.dconf=talk' 'org.freedesktop.impl.portal.PermissionStore=talk' 'org.freedesktop.portal.*=talk'; do
	printf '[Session Bus Policy]\n%s\n' "$grant" > "$scratch/overrides"
	if tg_check_repair_user_overrides > "$scratch/repair" <<< no; then exit 1; fi
	[[ ! -e $scratch/resets ]]
	grep -q 'were retained' "$scratch/repair"
	tg_check_repair_user_overrides > "$scratch/repair" <<< yes
	[[ $(wc -l < "$scratch/resets") == 1 ]]
	rm -- "$scratch/resets"
done

# Native consent remains authoritative for every configured scope. Missing and
# ask values deny; malformed stores fail instead of granting access.
for TG_CAMERA_MODE in none selected all; do
	for permission in no yes ask; do
		printf 'devices\tcamera\t%s\t%s\t0x00\ndevices\tmicrophone\t%s\t%s\t0x00\n' "$TG_APP" "$permission" "$TG_APP" "$permission" > "$scratch/portal"
		tg_check_native_consent > "$scratch/portal-result"
		if [[ $permission == yes ]]; then
			grep -q 'microphone consent: yes; camera consent: yes' "$scratch/portal-result"
		else
			grep -q 'microphone consent: no; camera consent: no' "$scratch/portal-result"
		fi
	done
	: > "$scratch/portal"
	tg_check_native_consent > "$scratch/portal-result"
	grep -q 'microphone consent: no; camera consent: no' "$scratch/portal-result"
done
printf 'devices\tcamera\t%s\tyes\t0x00\ndevices\tcamera\t%s\tyes\t0x00\n' "$TG_APP" "$TG_APP" > "$scratch/portal"
if tg_check_native_consent > /dev/null 2>&1; then exit 1; fi
printf 'malformed permission row\n' > "$scratch/portal"
if tg_check_native_consent > /dev/null 2>&1; then exit 1; fi

# Diagnostics identify inherited grants without clearing broad permission scopes.
: > "$scratch/overrides"
printf '[Session Bus Policy]\norg.freedesktop.systemd1.*=talk\norg.freedesktop.Notifications=talk\n' > "$scratch/user-global"
printf '[Session Bus Policy]\norg.freedesktop.Flatpak=talk\n' > "$scratch/system-app"
tg_check_diagnose_overrides > "$scratch/diagnostic"
grep -q 'user-global Flatpak overrides' "$scratch/diagnostic"
grep -q 'system-app Flatpak overrides' "$scratch/diagnostic"
grep -q 'flatpak override --system --show org.telegram.desktop' "$scratch/diagnostic"
if grep -q 'Notifications' "$scratch/diagnostic"; then exit 1; fi
[[ ! -e $scratch/resets ]]
# A raw broad grant may be masked by an exact app denial. An unrelated failed
# probe must not turn that raw entry into a requirement to edit global policy.
printf '[Session Bus Policy]\norg.freedesktop.systemd1=none\n' > "$scratch/overrides"
printf 'devices\tcamera\t%s\tno\t0x00\n' "$TG_APP" > "$scratch/portal"
if tg_check > "$scratch/masked-diagnostic"; then exit 1; fi
grep -q 'may be superseded' "$scratch/masked-diagnostic"
grep -q 'External Flatpak overrides are not changed automatically' "$scratch/masked-diagnostic"
if grep -q 'Resolve the global\|before retrying\|requires removal' "$scratch/masked-diagnostic"; then exit 1; fi
printf 'Telegram check rejects incomplete configuration and failed probes.\n'
