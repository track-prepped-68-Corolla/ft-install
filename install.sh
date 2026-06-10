#!/usr/bin/env bash
# ft-install — Bootstrap Lix + fast-track-nix ecosystem on any Linux machine.
#
# MODES
#   --emu   Lix + Home Manager + ft-emu emulation suite (any Linux distro)
#   --nix   Lix + Home Manager + fast-track-nix framework (any Linux distro)
#           Full NixOS installation is optional; run it later when you're ready.
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
  if [ -t 0 ]; then _tty="/dev/stdin"; else _tty="/dev/tty"; fi
  if [ -n "$_default" ]; then
    printf "${BOLD}  ? %s [%s]: ${NC}" "$_msg" "$_default" >/dev/tty 2>/dev/null || \
      printf "  ? %s [%s]: " "$_msg" "$_default"
  else
    printf "${BOLD}  ? %s: ${NC}" "$_msg" >/dev/tty 2>/dev/null || \
      printf "  ? %s: " "$_msg"
  fi
  local _reply
  read -r _reply < "$_tty"
  [ -z "$_reply" ] && _reply="$_default"
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
      printf "  --nix    Lix + Home Manager + fast-track-nix framework (any Linux)\n"
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
  printf " (Home Manager, any Linux distro)\n"
  printf "  ${BOLD}2) ft-nix${NC}  fast-track-nix Home Manager framework"
  printf " (any Linux distro, NixOS install optional later)\n\n"
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

# user_home <username>: resolve home directory without assuming /home/<user>.
user_home() {
  getent passwd "$1" 2>/dev/null | cut -d: -f6 || printf '/home/%s' "$1"
}

# activate_hm <flake-dir> <user> <system>: build and run the HM activation package.
# homeConfigurations are keyed "user@system" by the ft-home generator.
activate_hm() {
  local flake_dir="$1" hm_user="$2" hm_system="$3"
  local attr="homeConfigurations.\"${hm_user}@${hm_system}\".activationPackage"
  info "Building activation package..."
  local out
  out="$(nix build --no-link --print-out-paths "${flake_dir}#${attr}")"
  info "Activating..."
  "${out}/activate"
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
    ft_read flatpak_ok "Continue anyway? (config written, emulators won't install yet) [y/N]" "N"
    case "$flatpak_ok" in
      [yY]*) ;;
      *) die "Aborted. Install Flatpak first, then re-run with --emu." ;;
    esac
  fi

  ft_read USERNAME "Username"              "$(id -un)"
  ft_read EMU_PATH "Emulation library path" "${HOME}/Emulation"

  FLAKE_DIR="${HOME}/ft-emu"
  [ -d "${FLAKE_DIR}" ] && warn "${FLAKE_DIR} already exists — flake.nix will be overwritten."
  mkdir -p "${FLAKE_DIR}"

  info "Writing ${FLAKE_DIR}/flake.nix ..."

  # Bash variables (NIX_SYSTEM, USERNAME, EMU_PATH) expand here.
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
            home.homeDirectory = "$(user_home "${USERNAME}")";
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
  local attr="homeConfigurations.${USERNAME}.activationPackage"
  local out
  out="$(nix build --no-link --print-out-paths "${FLAKE_DIR}#${attr}")"
  "${out}/activate"

  step "Done"
  printf "\n"
  info "ft-emu is active for ${USERNAME}."
  printf "\n  Emulator configs:  %s/.configs/\n" "${EMU_PATH}"
  printf   "  ROMs:              %s/roms/\n"     "${EMU_PATH}"
  printf   "  BIOS files:        %s/bios/\n"     "${EMU_PATH}"
  printf   "  Saves:             %s/saves/\n"    "${EMU_PATH}"
  printf "\nTo update later:\n"
  printf "  cd %s && nix flake update\n" "${FLAKE_DIR}"
  printf "  nix build --no-link --print-out-paths .#homeConfigurations.%s.activationPackage | xargs -I{} {}/activate\n\n" \
    "${USERNAME}"
}

# ── Mode: ft-nix ───────────────────────────────────────────────────────────────
install_nix() {
  step "ft-nix setup"

  ft_read USERNAME    "Username"            "$(id -un)"
  ft_read REPO_DIR    "Config repo location" "${HOME}/nixos-config"

  HOME_DIR="$(user_home "${USERNAME}")"

  # ── Write config repo ──────────────────────────────────────────────────
  if [ -d "${REPO_DIR}" ] && [ -n "$(ls -A "${REPO_DIR}" 2>/dev/null)" ]; then
    warn "${REPO_DIR} already exists — skipping file generation, will re-activate."
  else
    mkdir -p "${REPO_DIR}"

    info "Writing flake.nix ..."
    cat > "${REPO_DIR}/flake.nix" <<NIXEOF
{
  description = "My NixOS + Home Manager configuration";

  inputs = {
    # fast-track-nix framework. Aliased as ft-home by consumer convention.
    ft-home.url = "github:track-prepped-68-corolla/fast-track-nix/testing";

    # Follow the framework's pins to avoid duplicate fetches and version drift.
    nixpkgs.follows = "ft-home/nixpkgs";
    home-manager.follows = "ft-home/home-manager";
    nixos-facter.follows = "ft-home/nixos-facter";
  };

  outputs =
    inputs @ { ft-home, ... }:
    ft-home.lib.mkFlake inputs;
}
NIXEOF

    # The generator reads var/local/system to determine which arch to build
    # homeConfigurations for when no machines/ entries are present.
    mkdir -p "${REPO_DIR}/var/local"
    printf '%s' "${NIX_SYSTEM}" > "${REPO_DIR}/var/local/system"

    info "Writing users/${USERNAME}/default.nix ..."
    mkdir -p "${REPO_DIR}/users/${USERNAME}"
    cat > "${REPO_DIR}/users/${USERNAME}/default.nix" <<NIXEOF
{ pkgs, lib, ... }:
{
  home.username = "${USERNAME}";
  home.homeDirectory = "${HOME_DIR}";
  home.stateVersion = "25.05";

  # Point at your repo on disk. Used by ft.terminal, ft.lazyvim, ft.dotfiles
  # to build live out-of-store symlinks into your config files.
  ft.repoPath = lib.mkDefault "${REPO_DIR}";

  # ft.core and ft.nixIndex are on by default.
  # Enable more features here as you go:
  #   ft.terminal.enable = true;   # Kitty, Ghostty, Zsh + Starship, bat, eza …
  #   ft.lazyvim.enable  = true;   # LazyVim Neovim config
  #   ft.theme.enable    = true;   # Stylix system-wide theming

  home.packages = with pkgs; [
    fastfetch
    htop
  ];
}
NIXEOF

    # Init git so Nix flake evaluation can see the files.
    run_git -C "${REPO_DIR}" init -q
    run_git -C "${REPO_DIR}" add -A
    run_git -C "${REPO_DIR}" \
      -c user.name="ft-install" \
      -c user.email="ft-install@localhost" \
      commit -q -m "init: ft-nix for ${USERNAME} on ${NIX_SYSTEM}"
  fi

  # ── Activate Home Manager ───────────────────────────────────────────────
  activate_hm "${REPO_DIR}" "${USERNAME}" "${NIX_SYSTEM}"

  step "Done"
  printf "\n"
  info "fast-track-nix Home Manager is active for ${USERNAME}."
  printf "\n  Config repo:  %s\n\n" "${REPO_DIR}"
  printf "Enable more features by editing:\n"
  printf "  %s/users/%s/default.nix\n" "${REPO_DIR}" "${USERNAME}"
  printf "Then rebuild:\n"
  printf "  cd %s\n" "${REPO_DIR}"
  printf "  git add -A && git commit -m 'feat: ...'\n"
  printf "  nix build --no-link --print-out-paths \".#homeConfigurations.%s@%s.activationPackage\" \\\'\n" \
    "${USERNAME}" "${NIX_SYSTEM}"
  printf "    | xargs -I{} {}/activate\n"
  printf "\n${BOLD}Optional: go full NixOS later${NC}\n\n"
  printf "  When you're ready to convert this machine to NixOS:\n"
  printf "  1. Boot from a NixOS live ISO on the target machine.\n"
  printf "  2. Generate hardware facts:\n"
  printf "       mkdir -p %s/machines/<name>/var\n" "${REPO_DIR}"
  printf "       nixos-facter -o %s/machines/<name>/var/facter.json\n" "${REPO_DIR}"
  printf "  3. Add machines/<name>/default.nix with ft.* options.\n"
  printf "  4. Deploy:\n"
  printf "       nixos-rebuild switch --flake %s#<name>\n\n" "${REPO_DIR}"
}

# ── Dispatch ───────────────────────────────────────────────────────────────────
case "$MODE" in
  emu) install_emu ;;
  nix) install_nix ;;
  *)   die "Internal error: unknown mode '${MODE}'" ;;
esac
