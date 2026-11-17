#!/usr/bin/env bash
# gentoo-niri-install.sh
#
# Installs Gentoo (amd64, UEFI, systemd) with the newest dist-kernel in the tree,
# the niri compositor and the Noctalia shell (GURU overlay).
#
# Run from the Gentoo minimal install ISO, as root, with working networking:
#   DISK=/dev/nvme0n1 NEW_USER=alice NEW_HOST=gentoo ./gentoo-niri-install.sh
#
# WARNING: DISK is completely erased.
#
# Layout:  ESP 1GiB (FAT32, /boot) | optional swap | XFS root (rest of disk)
# Boot:    systemd-boot via installkernel + dracut initramfs
# Network: NetworkManager

set -Eeuo pipefail

# ------------------------------- CONFIG ---------------------------------------
DISK="${DISK:-}"                          # e.g. /dev/sda or /dev/nvme0n1 (required)
NEW_HOST="${NEW_HOST:-gentoo}"
NEW_USER="${NEW_USER:-user}"
TIMEZONE="${TIMEZONE:-America/Kentucky/Louisville}"
LOCALE="${LOCALE:-en_US.UTF-8}"
KEYMAP="${KEYMAP:-us}"
SWAP_GIB="${SWAP_GIB:-8}"                 # 0 = no swap partition
KERNEL_PKG="${KERNEL_PKG:-gentoo-kernel-bin}"   # gentoo-kernel-bin (fast) | gentoo-kernel (compiled locally)
USE_BINHOST="${USE_BINHOST:-yes}"         # use Gentoo's official binary packages where they match
VIDEO_CARDS="${VIDEO_CARDS:-}"            # empty = auto-detect (amdgpu radeonsi | intel | nouveau)
MIRROR="${MIRROR:-https://distfiles.gentoo.org}"
GREETER_REF="${GREETER_REF:-}"            # noctalia-greeter git tag/branch if built from source (empty = latest tag)
STAGE3_FLAVOR="desktop-systemd"
MNT=/mnt/gentoo
SCRIPT_PATH="$(readlink -f "$0")"   # resolve now, before we cd away from the original directory
# ------------------------------------------------------------------------------

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
try()  { "$@" || warn "non-fatal failure: $*"; }

part() { # part <n>  -> partition device path
  if [[ $DISK == *[0-9] ]]; then echo "${DISK}p$1"; else echo "${DISK}$1"; fi
}

detect_video() {
  local g v=()
  g=$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d controller|display controller' || true)
  grep -Eqi 'amd|ati|radeon' <<<"$g" && v+=(amdgpu radeonsi)
  grep -qi 'intel'           <<<"$g" && v+=(intel)
  grep -qi 'nvidia'          <<<"$g" && v+=(nouveau)
  # Virtual machines: virtio-gpu (QEMU/KVM) uses Mesa's virgl driver; VMware/VirtualBox use vmware (svga).
  grep -Eqi 'virtio|red hat' <<<"$g" && v+=(virgl)
  grep -Eqi 'vmware|virtualbox' <<<"$g" && v+=(vmware)
  # QEMU guest with another display adapter: still build virgl so switching the VM to virtio-gpu works.
  if (( ${#v[@]} == 0 )) && grep -qiE 'qemu|kvm' /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null; then
    v+=(virgl)
  fi
  echo "${v[*]:-}"
}

# =============================== PHASE 1: live ISO ===========================
live_phase() {
  [[ $EUID -eq 0 ]]            || die "run as root"
  [[ -d /sys/firmware/efi ]]   || die "not booted in UEFI mode"
  [[ -n $DISK && -b $DISK ]]   || { lsblk -d -o NAME,SIZE,MODEL; die "set DISK=/dev/... (a block device)"; }
  [[ $KERNEL_PKG == gentoo-kernel-bin || $KERNEL_PKG == gentoo-kernel ]] || die "KERNEL_PKG must be gentoo-kernel-bin or gentoo-kernel"
  curl -fsI "$MIRROR" >/dev/null || die "no network / mirror unreachable"

  VIDEO_CARDS="${VIDEO_CARDS:-$(detect_video)}"
  [[ -n $VIDEO_CARDS ]] || warn "no GPU detected; set VIDEO_CARDS manually if graphics fail"
  [[ $VIDEO_CARDS == *nouveau* ]] && warn "NVIDIA GPU: using nouveau/NVK. The proprietary driver is not configured by this script."

  lsblk "$DISK"
  echo
  read -rp "This will ERASE ALL DATA on $DISK. Type the device path to confirm: " ans
  [[ $ans == "$DISK" ]] || die "confirmation mismatch"

  log "Partitioning $DISK"
  swapoff -a || true
  umount -R "$MNT" 2>/dev/null || true
  wipefs -af "$DISK"
  {
    echo "label: gpt"
    echo "size=1GiB, type=U, name=ESP"
    (( SWAP_GIB > 0 )) && echo "size=${SWAP_GIB}GiB, type=S, name=swap"
    echo "type=L, name=root"
  } | sfdisk "$DISK"
  udevadm settle; partprobe "$DISK" || true; sleep 2

  local esp swap="" root
  esp=$(part 1)
  if (( SWAP_GIB > 0 )); then swap=$(part 2); root=$(part 3); else root=$(part 2); fi

  log "Formatting"
  mkfs.vfat -F32 -n ESP "$esp"
  [[ -n $swap ]] && mkswap -L swap "$swap"
  mkfs.xfs -f -L gentoo "$root"

  log "Mounting"
  mkdir -p "$MNT"
  mount "$root" "$MNT"
  mkdir -p "$MNT/boot"
  mount "$esp" "$MNT/boot"
  [[ -n $swap ]] && swapon "$swap"

  log "Fetching latest stage3 ($STAGE3_FLAVOR)"
  local base="$MIRROR/releases/amd64/autobuilds" rel
  rel=$(curl -fsSL "$base/latest-stage3-amd64-${STAGE3_FLAVOR}.txt" \
        | awk '/\.tar\.xz/ {print $1; exit}')
  [[ -n $rel ]] || die "could not determine latest stage3"
  cd "$MNT"
  curl -fL --retry 3 -o stage3.tar.xz     "$base/$rel"
  curl -fL --retry 3 -o stage3.tar.xz.asc "$base/$rel.asc"

  log "Verifying stage3 signature"
  local gh; gh=$(mktemp -d)
  gpg --homedir "$gh" --import /usr/share/openpgp-keys/gentoo-release.asc 2>/dev/null
  gpg --homedir "$gh" --verify stage3.tar.xz.asc stage3.tar.xz \
    || die "stage3 signature verification FAILED"

  log "Unpacking stage3"
  tar xpf stage3.tar.xz --xattrs-include='*.*' --numeric-owner -C "$MNT"
  rm -f stage3.tar.xz stage3.tar.xz.asc

  log "Preparing chroot"
  cp --dereference /etc/resolv.conf "$MNT/etc/"
  mount --types proc /proc "$MNT/proc"
  mount --rbind /sys "$MNT/sys" && mount --make-rslave "$MNT/sys"
  mount --rbind /dev "$MNT/dev" && mount --make-rslave "$MNT/dev"
  mount --bind  /run "$MNT/run" && mount --make-slave  "$MNT/run"

  local root_uuid esp_uuid swap_uuid=""
  root_uuid=$(blkid -s UUID -o value "$root")
  esp_uuid=$(blkid -s UUID -o value "$esp")
  [[ -n $swap ]] && swap_uuid=$(blkid -s UUID -o value "$swap")

  declare -p NEW_HOST NEW_USER TIMEZONE LOCALE KEYMAP KERNEL_PKG USE_BINHOST \
             VIDEO_CARDS MIRROR GREETER_REF root_uuid esp_uuid swap_uuid > "$MNT/root/install.env"
  install -m 0755 "$SCRIPT_PATH" "$MNT/root/install.sh"

  log "Entering chroot"
  chroot "$MNT" /bin/bash /root/install.sh --chroot

  log "Cleaning up"
  rm -f "$MNT/root/install.env" "$MNT/root/install.sh"
  cd /
  umount -R "$MNT" || warn "could not unmount everything; reboot will sort it out"
  swapoff -a || true

  log "Done. Remove the install media and reboot."
  echo "greetd shows the Noctalia Greeter; log in as $NEW_USER and pick the niri session."
}

# ============================ greetd + Noctalia Greeter ======================
# Tries a GURU/overlay package first; otherwise builds noctalia-greeter from
# source (meson, --prefix=/usr, outside Portage). If that fails, falls back to
# tuigreet so you always end up with a working login screen.
build_greeter_from_source() {
  local src=/var/tmp/noctalia-greeter-src ref
  log "Building noctalia-greeter from source"
  emerge --noreplace dev-build/meson dev-build/ninja dev-vcs/git dev-util/pkgconf \
    dev-libs/wayland dev-libs/wayland-protocols dev-libs/libinput \
    media-libs/libglvnd media-libs/mesa media-libs/freetype media-libs/fontconfig \
    x11-libs/cairo x11-libs/pango media-libs/harfbuzz x11-libs/libxkbcommon dev-libs/glib \
    dev-cpp/tomlplusplus dev-cpp/nlohmann_json dev-libs/stb \
    media-libs/libwebp media-libs/libjxl gnome-base/librsvg dev-libs/libxml2 || return 1
  # The greeter targets wlroots 0.20; fall back to whatever slot is available.
  emerge --noreplace gui-libs/wlroots:0.20 || emerge --noreplace gui-libs/wlroots || return 1
  try emerge --noreplace dev-build/just

  rm -rf "$src"
  git clone --quiet https://github.com/noctalia-dev/noctalia-greeter "$src" || return 1
  ref="${GREETER_REF:-$(git -C "$src" tag --sort=-v:refname | head -n1)}"
  if [[ -n $ref ]]; then git -C "$src" checkout --quiet "$ref" || return 1; fi
  log "noctalia-greeter ref: ${ref:-default branch}"

  (
    cd "$src"
    meson setup build-release --prefix=/usr --buildtype=release
    if command -v just >/dev/null; then just build-release; else meson compile -C build-release; fi
    meson install -C build-release
  ) || return 1
  command -v noctalia-greeter-session >/dev/null
}

setup_greeter() {
  log "greetd + Noctalia Greeter"
  emerge --noreplace gui-libs/greetd sys-apps/accountsservice sys-auth/polkit

  local gu=greetd cmd ok=no
  getent passwd greetd >/dev/null || gu=greeter
  getent passwd "$gu"  >/dev/null || useradd -r -M -G video -s /sbin/nologin "$gu"

  if command -v noctalia-greeter-session >/dev/null 2>&1; then
    ok=yes   # already installed (e.g. on a re-run)
  elif emerge --pretend --quiet gui-apps/noctalia-greeter >/dev/null 2>&1; then
    emerge gui-apps/noctalia-greeter && ok=yes
  fi
  if [[ $ok != yes ]]; then
    build_greeter_from_source && ok=yes
  fi

  install -d /etc/greetd
  if [[ $ok == yes ]]; then
    cmd=$(command -v noctalia-greeter-session)
    try env GREETER_USER="$gu" noctalia-greeter-apply-appearance --setup-system
  else
    warn "Noctalia Greeter unavailable; falling back to tuigreet"
    emerge --noreplace gui-apps/tuigreet
    cmd="tuigreet --time --remember --cmd niri-session"
  fi

  cat > /etc/greetd/config.toml <<EOF
[terminal]
vt = 7

[default_session]
command = "${cmd}"
user = "${gu}"
EOF

  systemctl enable greetd.service
  try systemctl enable accounts-daemon.service
}

# =============================== PHASE 2: chroot =============================
chroot_phase() {
  # shellcheck disable=SC1091
  source /root/install.env
  set +u; source /etc/profile; set -u

  log "Syncing the Portage tree"
  emerge-webrsync

  log "Writing make.conf"
  local mem_gb jobs
  mem_gb=$(awk '/MemTotal/ {print int($2/1048576)}' /proc/meminfo)
  jobs=$(( mem_gb / 2 )); (( jobs < 1 )) && jobs=1
  (( jobs > $(nproc) )) && jobs=$(nproc)

  cat > /etc/portage/make.conf <<'EOF'
# Generated by gentoo-niri-install.sh
COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
LC_MESSAGES=C.utf8
USE="wayland vulkan pipewire dbus"
INPUT_DEVICES="libinput"
ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"
EOF
  {
    echo "MAKEOPTS=\"-j${jobs} -l${jobs}\""
    echo "EMERGE_DEFAULT_OPTS=\"--jobs=2 --load-average=${jobs} --quiet-build\""
    echo "VIDEO_CARDS=\"${VIDEO_CARDS}\""
    echo "GENTOO_MIRRORS=\"${MIRROR}\""
    [[ $USE_BINHOST == yes ]] && echo 'FEATURES="getbinpkg binpkg-request-signature"'
  } >> /etc/portage/make.conf

  if [[ $VIDEO_CARDS == *virgl* ]]; then
    log "Virtual machine graphics: adding virtio drivers to the initramfs"
    mkdir -p /etc/dracut.conf.d
    echo 'add_drivers+=" virtio_gpu virtio_pci virtio_blk virtio_scsi "' > /etc/dracut.conf.d/10-virtio.conf
  fi

  log "Portage configuration (keywords / USE)"
  mkdir -p /etc/portage/package.use /etc/portage/package.accept_keywords
  cat > /etc/portage/package.accept_keywords/desktop <<EOF
# Newest kernel in the tree
sys-kernel/${KERNEL_PKG} ~amd64
virtual/dist-kernel ~amd64
# niri + Noctalia come from GURU and are keyworded ~amd64
gui-wm/niri ~amd64
gui-apps/noctalia ~amd64
gui-apps/noctalia-greeter ~amd64
gui-apps/xwayland-satellite ~amd64
gui-apps/tuigreet ~amd64
gui-libs/wlroots ~amd64
app-misc/cliphist ~amd64
EOF
  cat > /etc/portage/package.use/desktop <<'EOF'
gui-wm/niri systemd dbus screencast
sys-apps/systemd boot kernel-install
sys-kernel/installkernel systemd systemd-boot dracut
media-video/pipewire sound-server
EOF

  log "Timezone, locale, hostname"
  ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
  grep -qx "${LOCALE} UTF-8" /etc/locale.gen || echo "${LOCALE} UTF-8" >> /etc/locale.gen
  locale-gen
  eselect locale set "$(eselect locale list | awk -v l="${LOCALE/UTF-8/utf8}" '$2==l {print $1; exit}' | tr -d '[]')" || true
  echo "$NEW_HOST" > /etc/hostname
  echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
  set +u; env-update; source /etc/profile; set -u

  log "fstab"
  {
    echo "UUID=${root_uuid}  /      xfs   defaults,noatime  0 1"
    echo "UUID=${esp_uuid}   /boot  vfat  umask=0077        0 2"
    [[ -n $swap_uuid ]] && echo "UUID=${swap_uuid}  none   swap  sw                0 0"
  } > /etc/fstab

  log "CPU flags"
  emerge --oneshot app-portage/cpuid2cpuflags
  echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags

  log "Enabling GURU overlay"
  emerge --noreplace app-eselect/eselect-repository dev-vcs/git
  eselect repository enable guru
  emaint sync -r guru

  log "Updating @world (this is the long part)"
  emerge --verbose --update --deep --newuse @world

  log "Bootloader prerequisites"
  systemd-machine-id-setup
  echo "root=UUID=${root_uuid} rw quiet" > /etc/kernel/cmdline
  emerge --noreplace sys-kernel/installkernel sys-fs/dosfstools sys-fs/xfsprogs
  bootctl install || bootctl install --no-variables

  log "Kernel: sys-kernel/${KERNEL_PKG} (~amd64 = newest in tree)"
  emerge sys-kernel/linux-firmware "sys-kernel/${KERNEL_PKG}"

  log "Base system"
  emerge --noreplace net-misc/networkmanager app-admin/sudo sys-apps/pciutils \
         app-shells/bash-completion app-editors/nano

  chroot_desktop
}

# Second half of the chroot work (desktop, greeter, services, user).
# Can be re-run on its own:  chroot /mnt/gentoo /bin/bash /root/install.sh --chroot-desktop
chroot_desktop() {
  log "Letting Portage unmask ~amd64 dependencies of niri/Noctalia automatically"
  grep -q autounmask-continue /etc/portage/make.conf \
    || sed -i 's/^EMERGE_DEFAULT_OPTS="/EMERGE_DEFAULT_OPTS="--autounmask-continue /' /etc/portage/make.conf
  grep -qx 'dev-cpp/sdbus-c++ ~amd64' /etc/portage/package.accept_keywords/desktop \
    || echo 'dev-cpp/sdbus-c++ ~amd64' >> /etc/portage/package.accept_keywords/desktop

  # Keywords / license / USE for Steam, MangoHud, Goverlay and Brave Origin
  mkdir -p /etc/portage/package.license /etc/portage/package.use
  cat > /etc/portage/package.accept_keywords/gaming <<'EOF'
www-client/brave-origin ~amd64
games-util/steam-launcher ~amd64
games-util/mangohud ~amd64
games-util/goverlay ~amd64
EOF
  cat > /etc/portage/package.license/gaming <<'EOF'
games-util/steam-launcher ValveSteamLicense
EOF
  # 32-bit MangoHud layer for 32-bit Steam games (Portage ignores it if the flag doesn't exist)
  cat > /etc/portage/package.use/gaming <<'EOF'
games-util/mangohud abi_x86_32
EOF
  log "Desktop: niri + Noctalia"
  emerge gui-wm/niri gui-apps/noctalia
  # sensible companions; none of these are fatal if missing
  # Installed one at a time: a single masked/missing package must not block the rest.
  # (Noctalia has its own launcher, so fuzzel is no longer installed.)
  for pkg in x11-terms/alacritty gui-apps/xwayland-satellite \
             sys-apps/xdg-desktop-portal sys-apps/xdg-desktop-portal-gnome sys-apps/xdg-desktop-portal-gtk \
             media-video/pipewire media-video/wireplumber \
             media-fonts/noto media-fonts/noto-emoji; do
    emerge --noreplace "$pkg" || warn "could not install $pkg (skipped)"
  done
  # Noctalia optional features: night light, clipboard history, power profiles, bluetooth
  for pkg in gui-apps/wlsunset app-misc/cliphist sys-power/power-profiles-daemon net-wireless/bluez; do
    emerge --noreplace "$pkg" || warn "could not install $pkg (skipped)"
  done

  # Brave Origin (third-party overlay) and Steam (steam-overlay). Both are outside the
  # official Gentoo tree. Steam is 32-bit, so Portage will also rebuild Mesa and other
  # libraries with 32-bit support; that can add a lot of compile time.
  log "Overlays: steam-overlay, another-brave-overlay"
  try eselect repository enable steam-overlay
  eselect repository list -i 2>/dev/null | grep -q another-brave-overlay \
    || try eselect repository add another-brave-overlay git https://github.com/iFanatical/another-brave-overlay.git
  try emaint sync -r steam-overlay
  try emaint sync -r another-brave-overlay

  log "Brave Origin, MangoHud, Goverlay, Steam"
  for pkg in www-client/brave-origin games-util/mangohud games-util/goverlay games-util/steam-launcher; do
    emerge --noreplace "$pkg" || warn "could not install $pkg (skipped)"
  done

  setup_greeter

  log "Services"
  systemctl enable NetworkManager.service
  systemctl enable systemd-timesyncd.service
  try systemctl enable power-profiles-daemon.service
  try systemctl enable bluetooth.service
  try systemctl --global enable pipewire.socket pipewire-pulse.socket wireplumber.service
  systemctl preset-all --preset-mode=enable-only || true

  log "User account"
  id "$NEW_USER" >/dev/null 2>&1 || useradd -m -G wheel,video,audio,input -s /bin/bash "$NEW_USER"
  install -d -m 0750 /etc/sudoers.d
  echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel
  chmod 0440 /etc/sudoers.d/wheel
  try visudo -c

  # Starter niri config: Noctalia autostart + its recommended rules/binds.
  # (A user config replaces niri's built-in defaults, so core binds are included.)
  install -d "/home/${NEW_USER}/.config/niri"
  cat > "/home/${NEW_USER}/.config/niri/config.kdl" <<EOF
input {
    keyboard {
        xkb {
            layout "${KEYMAP}"
        }
    }
    touchpad {
        tap
        natural-scroll
    }
}

layout {
    gaps 8
    default-column-width { proportion 0.5; }
}

prefer-no-csd

spawn-at-startup "noctalia"

window-rule {
    geometry-corner-radius 20
    clip-to-geometry true
}

// Float the Noctalia settings window.
window-rule {
    match app-id="dev.noctalia.Noctalia"
    open-floating true
    default-column-width { fixed 1080; }
    default-window-height { fixed 920; }
}

debug {
    // Lets Noctalia notification actions activate windows.
    honor-xdg-activation-with-invalid-serial
}

binds {
    Mod+Shift+Slash { show-hotkey-overlay; }
    Mod+Return { spawn "alacritty"; }
    Mod+Q { close-window; }
    Mod+Shift+E { quit; }

    Mod+Left  { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Down  { focus-window-down; }
    Mod+Up    { focus-window-up; }
    Mod+Shift+Left  { move-column-left; }
    Mod+Shift+Right { move-column-right; }
    Mod+Page_Down { focus-workspace-down; }
    Mod+Page_Up   { focus-workspace-up; }
    Mod+F { maximize-column; }
    Mod+Shift+F { fullscreen-window; }
    Mod+V { toggle-window-floating; }
    Print { screenshot; }

    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }

    // Noctalia
    Mod+Space { spawn-sh "noctalia msg panel-toggle launcher"; }
    Mod+S { spawn-sh "noctalia msg panel-toggle control-center"; }
    Mod+Shift+Comma { spawn-sh "noctalia msg settings-toggle"; }
    Alt+Tab { spawn-sh "noctalia msg window-switcher hold"; }
    XF86AudioRaiseVolume { spawn-sh "noctalia msg volume-up"; }
    XF86AudioLowerVolume { spawn-sh "noctalia msg volume-down"; }
    XF86AudioMute { spawn-sh "noctalia msg volume-mute"; }
    XF86MonBrightnessUp { spawn-sh "noctalia msg brightness-up"; }
    XF86MonBrightnessDown { spawn-sh "noctalia msg brightness-down"; }
}
EOF
  chown -R "${NEW_USER}:" "/home/${NEW_USER}"

  # Optional: let this user sync Noctalia's appearance to the greeter without a password prompt
  if command -v noctalia-greeter >/dev/null; then
    try noctalia-greeter passwordless-sync enable "$NEW_USER"
  fi

  log "Passwords"
  echo "Set root password:";            until passwd root;            do :; done
  echo "Set password for ${NEW_USER}:"; until passwd "$NEW_USER";     do :; done

  log "Chroot phase complete"
}

# ================================ entrypoint =================================
case "${1:-}" in
  --chroot)
    chroot_phase
    ;;
  --chroot-desktop)
    # shellcheck disable=SC1091
    source /root/install.env
    set +u; source /etc/profile; set -u
    chroot_desktop
    ;;
  *)
    live_phase
    ;;
esac
