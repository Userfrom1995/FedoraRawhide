Fedora Rawhide for WSL & VMware
===============================

Ready-to-use Fedora Rawhide images for Windows Subsystem for Linux (WSL) 2 and VMware Workstation Pro. Install it, and you're running the latest Fedora.

Fedora Rawhide is the rolling-development branch of Fedora. It always has the latest packages, but it moves fast. This project wraps it into `.wsl` and `.ova` archives that stay current with a new automated build every week.

-------------------------------------------------------
Features
-------------------------------------------------------

- **Always up to date** — a new rootfs is built every Monday from the latest Rawhide repository, so you're never more than a week behind.
- **Systemd support** — works out of the box on WSL2.
- **First-run user setup** — on first launch, you create your own user account with passwordless sudo. No pre-baked users, no default passwords.
- **WSLg integration** — X11, Wayland, and PulseAudio are wired up automatically so Linux GUI apps just work.
- **Minimal footprint** — only the essentials are included (`@core`, `dnf5`, `systemd`, `polkit`). You decide what else to install.
- **Weekly automated builds** — GitHub Actions rebuilds the rootfs every Monday at 6:00 AM UTC and publishes it as a dated release. You can also trigger a build manually at any time.
- **Transparent build process** — the full build script is in this repository. You can inspect it, modify it, or run it yourself.

-------------------------------------------------------
How to Get Started
-------------------------------------------------------

1. Download the Fedora Rawhide `.wsl` package:
   - From the GitHub Releases section

2. Install the distro into WSL:

   PowerShell or Windows Terminal from a normal Windows path such as `Downloads` or `C:\WSL`:

   ```
   wsl --install --from-file C:\path\to\Fedora-Rawhide-WSL.wsl
   ```

   You can also install it by double-clicking the `.wsl` file in File Explorer.
   If you want to override the default registration name, use:

   ```
   wsl --install --from-file C:\path\to\Fedora-Rawhide-WSL.wsl --name fedora-rawhide
   ```

   Avoid launching the installer from a `\\wsl.localhost\...` path. WSL may try to inherit that UNC working directory when it auto-launches the new distro after installation, which can produce a harmless `Failed to translate '\\wsl.localhost\...'` warning.

3. Launch Fedora:

   ```
   wsl -d fedora-rawhide
   ```

4. Complete the first-run setup:
   - Enter the username you want to use.
   - Fedora will use that account as the default user with passwordless sudo.

5. Update packages after first boot (recommended):

   ```
   sudo dnf5 upgrade
   ```

   The `.wsl` image is a snapshot of Rawhide at build time. Running `dnf5 upgrade` pulls the latest packages.

6. Open VS Code and connect to your Fedora instance through WSL:
   - Install the "Remote - WSL" extension in VS Code.
   - Click on the green >< icon in the lower-left corner and select "Remote-WSL: New Window".
   - From there, you can open the Fedora filesystem and start developing with all the conveniences of VS Code.

7. Verify your WSL version if you still see systemd warnings:

   ```
   wsl --version
   ```

   The `.wsl` package flow requires WSL 2.4.4 or newer. If you still see `Failed to start the systemd user session`, update WSL before troubleshooting the distro further.

-------------------------------------------------------
First-Run User Setup
-------------------------------------------------------

The image uses WSL's supported out-of-box experience (OOBE) flow:

- No fixed non-root user is baked into the image.
- The first launch prompts you to create your own default user.
- The created user gets passwordless sudo access via a dedicated sudoers file and is added to the `wheel` group.
- No password is set during setup — run `sudo passwd <username>` later if you want one.

### Important Note :
>The legacy `wsl --import` flow bypasses the OOBE experience and can still launch the distro as `root`. Use the `.wsl` installer flow shown above if you want the first-run user creation to work correctly.

-------------------------------------------------------
How to Use with VMware Workstation Pro
-------------------------------------------------------

1. Download `Fedora-Rawhide-VMware.ova` from GitHub Releases.
2. In VMware Workstation Pro, click **File → Open...** (or double-click the `.ova` file).
3. Choose a name and local folder for the VM and click **Import**.
4. Power on the VM:
   - **Default user**: `fedora`
   - **Password**: `fedora` (passwordless sudo enabled)
   - **Console autologin**: Automatically logs in to `tty1` on first boot.
   - **VMware tools**: `open-vm-tools` is pre-installed for automatic display scaling, host clipboard sharing, and time sync.

-------------------------------------------------------
Releases
-------------------------------------------------------

Releases are built automatically every week by GitHub Actions on Monday at 6:00 AM UTC and tagged with the build date:

```
rawhide-2026-07-15-0600
 ^^^^^^^  ^^^^^^^^ ^^^^
 repo     date     time (UTC)
```

- **New tag on each release** — each build is a unique, immutable snapshot.
- **Older releases are deleted automatically** — only the last month of builds is kept.
- **Manual builds** — the maintainer can trigger a build at any time from the Actions tab. A same-day build gets a unique time-stamped tag (e.g. `rawhide-2026-07-15-1430`).

If you downloaded an image a while ago, just run `sudo dnf5 upgrade` after first boot to get the latest packages.

-------------------------------------------------------
Transparency and Build Steps
-------------------------------------------------------

This repository includes the build scripts used to generate the release artifacts:

- **WSL 2 (.wsl)**:
  ```bash
  ./rawhide/build-rawhide.sh
  ```
  Emits `rawhide/Fedora-Rawhide-WSL.wsl`.

- **VMware Workstation Pro (.ova & .vmdk)**:
  ```bash
  ./rawhide/build-vmware.sh
  ```
  Emits `rawhide/Fedora-Rawhide-VMware.ova` and `rawhide/Fedora-Rawhide-VMware.vmdk`.

-------------------------------------------------------
License
-------------------------------------------------------

This project is licensed under the MIT License.

Fedora is a registered trademark of Red Hat, Inc., and is used here in a community capacity for educational and practical purposes. This project is not affiliated with or endorsed by Red Hat.
