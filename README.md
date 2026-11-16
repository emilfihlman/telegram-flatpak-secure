# Telegram Flatpak Secure

Telegram Desktop from Flathub, with configurable camera and microphone access.

## How it works

```mermaid
flowchart LR
	installed["Existing Flatpak<br/>Telegram + runtime"]
	wrapper["Our launcher + hook<br/>Applies access rules"]
	cameras["Camera allowlist<br/>Selected / all / none"]
	audio["Audio access<br/>Mic on / playback only"]
	subgraph sandbox["Flatpak's bubblewrap sandbox"]
		telegram["Telegram Desktop"]
	end
	installed --> wrapper
	cameras --> wrapper
	audio --> wrapper
	wrapper -->|Only approved access| telegram
```

The launcher customizes **Flatpak's own sandbox at each launch**, using permission overrides and a bubblewrap hook. It removes broad filesystem, device and host-service access, then adds the approved camera devices and audio socket. Linux namespaces and bind mounts control what Telegram can see and access. The configured profile, Telegram downloads, network, GPU and desktop display remain available; microphone blocking keeps sound playback available.

## Setup

Open a terminal in your X11 or Wayland desktop session on Debian and run:

```bash
./telegram-setup.bash
```

Setup installs or updates Telegram and asks which cameras it may use and whether to allow the microphone. It shows the current camera selection and available cameras. Choose camera numbers, `all`, or `none`; press Enter to keep the current choice.

Launch **Telegram** from the application menu afterward. Setup routes the menu entry, `tg:` links and existing Telegram autostart entries through the wrapper. It asks before replacing an existing launcher.

The same launcher uses Wayland when available and falls back to X11 automatically. X11 shares display access between applications; Wayland provides stronger display isolation.

Run `./telegram-setup.bash` again to update Telegram, change camera/microphone access, choose an existing Telegram profile, check and repair the setup, or remove the wrapper. Repeated setup keeps the current choices unless you change them. Profiles and downloads are retained.

Microphone blocking keeps sound playback available. Camera access can be limited to selected cameras or allowed for all cameras.

Restart Telegram after connecting a camera that was absent when it started. Launch errors are recorded in `$XDG_RUNTIME_DIR/telegram-sandbox.log` when started from setup; use **Check / repair** to diagnose sandbox and launch configuration.

[MIT license](LICENSE)
