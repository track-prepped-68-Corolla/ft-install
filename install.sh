#!/usr/bin/env bash
# ft-install — Bootstrap Lix + fast-track-nix ecosystem on any Linux machine.
#
# MODES
#   --emu   Lix + Home Manager + ft-emu emulation suite (any Linux distro)
#   --nix   Lix + clone ft-template to start a NixOS configuration
#
# USAGE (interactive — process substitution keeps stdin available for prompts)
#   sh <(curl -fsSL https://raw.githubusercontent.com/track-prepped-68-corolla/ft-install/main/install.sh)
#
# USAGE (non-interactive)
#   curl -fsSL ... | sh -s -- --emu
#   curl -fsSL ... | sh -s -- --nix

set -euo pipefail

# ── Output helpers ─────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m'
  BLUE='\033[0;34m' BOLD='\033[1m' NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

info() { printf "${GREEN}  => %s${NC}\n" "$*"; }
warn() { printf "${YELLOW}  !  %s${NC}\n" "$*" >&2; }
step() { printf "\n${BOLD}${BLUE}── %s ──${NC}\n" "$*"; }
die()  { printf "${RED}  x  %s${NC}\n" "$*" >&2; exit 1; }

# Read a value from the terminal, even when stdin is a pipe.
# Usage: ft_read VARNAME "Prompt text" "default"
ft_read() {
  local _var="$1" _msg="$2" _default="${3:-}"
  local _tty
  if [ -t 0 ]; then
    _tty="/dev/stdin"
  else
    _tty="/dev/tty"
  fi
  if [ -n "$_default" ]; then
    printf "${BOLD}  ? %s [%s]: ${NC}" "$_msg" "$_default" >/dev/tty 2>/dev/null || \
      printf "  ? %s [%s]: " "$_msg" "$_default"
  else
    printf "${BOLD}  ? %s: ${NC}" "$_msg" >/dev/tty 2>/dev/null || \
      printf "  ? %s: " "$_msg"
  fi
  local _reply
  read -r _reply < "$_tty"
  if [ -z "$_reply" ] && [ -n "$_default" ]; then
    _reply="$_default"
  fi
  # Use printf -v to assign without eval
  printf -v "$_var" '%s' "$_reply"
}

# ── Arg parsing ────────────────────────────────────────────────────────────────
MODE=""
for arg in "$@"; do
  case "$arg" in
    --emu)    MODE="emu" ;;
    --nix)    MODE="nix" ;;
    --help|-h)
      printf "ft-install — Bootstrap Lix + fast-track-nix ecosystem\n\n"
      printf "  --emu    Lix + Home Manager + ft-emu emulation suite (any Linux)\n"
      printf "  --nix    Lix + ft-template consumer repo (NixOS framework)\n"
      printf "  --help   Show this message\n"
      exit 0
      ;;
    *) die "Unknown argument: $arg  (use --help for usage)" ;;
  esac
done

# ── System detection ───────────────────────────────────────────────────────────
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)  NIX_SYSTEM="x86_64-linux" ;;
  aarch64) NIX_SYSTEM="aarch64-linux" ;;
  *)       die "Unsupported architecture: $ARCH (only x86_64 and aarch64 are supported)" ;;
esac

# ── Banner ─────────────────────────────────────────────────────────────────────
printf "\n${BOLD}fast-track-nix installer${NC}  (%s)\n" "$NIX_SYSTEM"

# ── Mode selection ─────────────────────────────────────────────────────────────
if [ -z "$MODE" ]; then
  printf "\nWhat do you want to install?\n\n"
  printf "  ${BOLD}1) ft-emu${NC}  EmuDeck-compatible emulation suite"
  printf " (Lix + Home Manager, any Linux distro)\n"
  printf "  ${BOLD}2) ft-nix${NC}  NixOS configuration framework"
  printf " (Lix + ft-template consumer repo)\n\n"
  ft_read choice "Enter 1 or 2"
  case "$choice" in
    1|emu|ft-emu) MODE="emu" ;;
    2|nix|ft-nix) MODE="nix" ;;
    *) die "Invalid choice: '$choice'" ;;
  esac
fi

# ── Lix installation ───────────────────────────────────────────────────────────
step "Lix"

NIX_DAEMON_PROFILE="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
NIX_USER_PROFILE="${HOME}/.nix-profile/etc/profile.d/nix.sh"

source_nix() {
  # shellcheck disable=SC1090,SC1091
  if [ -f "$NIX_DAEMON_PROFILE" ]; then
    . "$NIX_DAEMON_PROFILE"
  elif [ -f "$NIX_USER_PROFILE" ]; then
    . "$NIX_USER_PROFILE"
  fi
}

if command -v nix >/dev/null 2>&1; then
  info "Already installed: $(nix --version) — skipping Lix installer."
else
  command -v curl >/dev/null 2>&1 || die "curl is required but not found."
  info "Running Lix installer (multi-user, requires sudo)..."
  curl -sSf -L https://install.lix.systems/lix | sh -s -- install --no-confirm
  source_nix
  command -v nix >/dev/null 2>&1 || \
    die "Lix installed but 'nix' is not on PATH. Open a new shell and re-run."
  info "Installed: $(nix --version)"
fi

source_nix

# Enable flakes + nix-command (Lix has these on by default; belt-and-braces).
export NIX_CONFIG="extra-experimental-features = nix-command flakes"

# ── Helpers ────────────────────────────────────────────────────────────────────

# run_git: use system git if available, otherwise pull it from nixpkgs.
run_git() {
  if command -v git >/dev/null 2>&1; then
    git "$@"
  else
    nix run nixpkgs#git -- "$@"
  fi
}

# ── Mode: ft-emu ───────────────────────────────────────────────────────────────
install_emu() {
  step "ft-emu setup"

  # Flatpak is the delivery mechanism for emulators.
  if ! command -v flatpak >/dev/null 2>&1; then
    warn "flatpak is not installed on this system."
    warn "ft-emu installs emulators via Flatpak — install it first, then re-run."
    printf "\n  Ubuntu/Debian:  sudo apt install flatpak\n"
    printf   "  Fedora:         sudo dnf install flatpak\n"
    printf   "  Arch:           sudo pacman -S flatpak\n"
    printf   "  openSUSE:       sudo zypper install flatpak\n\n"
    ft_read flatpak_ok "Continue anyway? (the config will be written but emulators won't install) [y/N]" "N"
    case "$flatpak_ok" in
      [yY]*) ;;
      *) die "Aborted. Install Flatpak first, then re-run with --emu." ;;
    esac
  fi

  ft_read USERNAME  "Username"               "$(id -un)"
  ft_read EMU_PATH  "Emulation library path"  "${HOME}/Emulation"

  FLAKE_DIR="${HOME}/ft-emu"
  if [ -d "${FLAKE_DIR}" ]; then
    warn "${FLAKE_DIR} already exists — flake.nix will be overwritten."
  fi
  mkdir -p "${FLAKE_DIR}"

  info "Writing ${FLAKE_DIR}/flake.nix ..."

  # Bash variables (NIX_SYSTEM, USERNAME, EMU_PATH) are expanded here.
  # Nix interpolations use \${...} so they survive into the written file as ${...}.
  cat > "${FLAKE_DIR}/flake.nix" <<NIXEOF
{
  description = "ft-emu home configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ft-emu.url = "github:track-prepped-68-corolla/fast-track-emu";
  };

  outputs =
    {
      nixpkgs,
      home-manager,
      ft-emu,
      ...
    }:
    let
      system = "${NIX_SYSTEM}";
      pkgs = nixpkgs.legacyPackages.\${system};
      username = "${USERNAME}";
    in
    {
      homeConfigurations.\${username} = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          ft-emu.homeManagerModules.default
          {
            home.username = username;
            home.homeDirectory = "/home/\${username}";
            home.stateVersion = "25.05";

            ft.emulation = {
              enable = true;
              emulationPath = "${EMU_PATH}";
            };
          }
        ];
      };
    };
}
NIXEOF

  info "Building and activating Home Manager configuration..."
  ACTIVATION="$(nix build --no-link --print-out-paths \
    "${FLAKE_DIR}#homeConfigurations.${USERNAME}.activationPackage")"
  "${ACTIVATION}/activate"

  step "Done"
  printf "\n"
  info "ft-emu is active for ${USERNAME}."
  printf "\n"
  printf "  Emulator configs:  %s/.configs/\n" "${EMU_PATH}"
  printf "  ROMs:              %s/roms/\n"     "${EMU_PATH}"
  printf "  BIOS files:        %s/bios/\n"     "${EMU_PATH}"
  printf "  Saves:             %s/saves/\n"    "${EMU_PATH}"
  printf "\n"
  printf "To update later:\n"
  printf "  cd %s\n" "${FLAKE_DIR}"
  printf "  nix flake update\n"
  printf "  nix run .#homeConfigurations.%s.activationPackage\n\n" "${USERNAME}"
}

# ── Mode: ft-nix ───────────────────────────────────────────────────────────────
install_nix() {
  step "ft-nix setup"

  if [ ! -f /etc/NIXOS ] && [ ! -f /etc/nixos/configuration.nix ]; then
    warn "This machine is not running NixOS."
    warn "ft-nix is a NixOS configuration framework. This step sets up your"
    warn "consumer repo so you can deploy with nixos-anywhere from a live ISO."
    printf "\n"
  fi

  ft_read REPO_DIR     "Consumer repo location" "${HOME}/ft-home"
  ft_read MACHINE_NAME "Machine name"           "$(hostname -s 2>/dev/null || echo my-machine)"
  ft_read PRIMARY_USER "Primary username"        "$(id -un)"

  # ── Clone ft-template ────────────────────────────────────────────────────
  if [ -d "${REPO_DIR}/.git" ]; then
    warn "${REPO_DIR} is already a git repo — skipping clone."
  elif [ -d "${REPO_DIR}" ] && [ -n "$(ls -A "${REPO_DIR}" 2>/dev/null)" ]; then
    warn "${REPO_DIR} already exists and is non-empty — skipping clone."
  else
    info "Cloning ft-template to ${REPO_DIR} ..."
    run_git clone \
      https://github.com/track-prepped-68-corolla/ft-template.git \
      "${REPO_DIR}"
    # Detach from the template remote; the user will add their own.
    rm -rf "${REPO_DIR}/.git"
    run_git -C "${REPO_DIR}" init
    run_git -C "${REPO_DIR}" add -A
    run_git -C "${REPO_DIR}" \
      -c user.name="ft-install" \
      -c user.email="ft-install@localhost" \
      commit -m "init: clone ft-template"
  fi

  # ── Rename machines/example → machines/<name> ─────────────────────────────
  MACH_SRC="${REPO_DIR}/machines/example"
  MACH_DST="${REPO_DIR}/machines/${MACHINE_NAME}"
  if [ -d "${MACH_SRC}" ] && [ ! -d "${MACH_DST}" ]; then
    info "Renaming machines/example → machines/${MACHINE_NAME} ..."
    mv "${MACH_SRC}" "${MACH_DST}"
    MACH_NIX="${MACH_DST}/default.nix"
    sed -i \
      -e "s|networking\.hostName = \"example\"|networking.hostName = \"${MACHINE_NAME}\"|g" \
      -e "s|mainUser = \"example\"|mainUser = \"${PRIMARY_USER}\"|g" \
      -e "s|superUsers = \[ \"example\" \]|superUsers = [ \"${PRIMARY_USER}\" ]|g" \
      -e "s|initialPasswords\.example|initialPasswords.${PRIMARY_USER}|g" \
      -e "s|/home/example/ft-template|/home/${PRIMARY_USER}/ft-home|g" \
      "${MACH_NIX}"
  fi

  # ── Rename users/example → users/<user> ──────────────────────────────────
  USER_SRC="${REPO_DIR}/users/example"
  USER_DST="${REPO_DIR}/users/${PRIMARY_USER}"
  if [ -d "${USER_SRC}" ] && [ ! -d "${USER_DST}" ]; then
    info "Renaming users/example → users/${PRIMARY_USER} ..."
    mv "${USER_SRC}" "${USER_DST}"
    USER_NIX="${USER_DST}/default.nix"
    sed -i \
      -e "s|home\.username = \"example\"|home.username = \"${PRIMARY_USER}\"|g" \
      -e "s|/home/example/ft-template|/home/${PRIMARY_USER}/ft-home|g" \
      -e "s|userName = \"example\"|userName = \"${PRIMARY_USER}\"|g" \
      -e "s|userEmail = \"example@fasttrack\.os\"|userEmail = \"${PRIMARY_USER}@fasttrack.os\"|g" \
      "${USER_NIX}"
  fi

  # ── Record local system info ───────────────────────────────────────────────
  mkdir -p "${REPO_DIR}/var/local"
  printf '%s' "${NIX_SYSTEM}"   > "${REPO_DIR}/var/local/system"
  printf '%s' "${MACHINE_NAME}" > "${REPO_DIR}/var/local/machineName"

  # ── Commit personalisation ────────────────────────────────────────────────
  run_git -C "${REPO_DIR}" add -A
  if ! run_git -C "${REPO_DIR}" diff --cached --quiet 2>/dev/null; then
    run_git -C "${REPO_DIR}" \
      -c user.name="ft-install" \
      -c user.email="ft-install@localhost" \
      commit -m "bootstrap: personalise for ${MACHINE_NAME} / ${PRIMARY_USER}"
  fi

  step "Repository ready"
  printf "\n  %s  at  %s\n\n" "${MACHINE_NAME}" "${REPO_DIR}"
  printf "Next steps:\n\n"
  printf "  1. Generate hardware facts on the target (from a NixOS live ISO):\n\n"
  printf "       ssh root@<ip> \\\n"
  printf "         'nix run github:numtide/nixos-facter -- -o /tmp/facter.json \\\n"
  printf "          && cat /tmp/facter.json' \\\n"
  printf "         > %s/machines/%s/var/facter.json\n\n" \
    "${REPO_DIR}" "${MACHINE_NAME}"
  printf "  2. Review the machine config:\n"
  printf "       %s/machines/%s/default.nix\n\n" "${REPO_DIR}" "${MACHINE_NAME}"
  printf "  3. Deploy with nixos-anywhere:\n\n"
  printf "       nix run github:nix-community/nixos-anywhere -- \\\n"
  printf "         --flake %s#%s root@<ip>\n\n" "${REPO_DIR}" "${MACHINE_NAME}"
  printf "  Or, if already on NixOS:\n"
  printf "       sudo nixos-rebuild switch --flake %s#%s\n\n" \
    "${REPO_DIR}" "${MACHINE_NAME}"
  printf "  4. Add your git remote when ready:\n"
  printf "       git -C %s remote add origin <your-repo-url>\n\n" "${REPO_DIR}"
}

# ── Dispatch ───────────────────────────────────────────────────────────────────
case "$MODE" in
  emu) install_emu ;;
  nix) install_nix ;;
  *)   die "Internal error: unknown mode '${MODE}'" ;;
esac
