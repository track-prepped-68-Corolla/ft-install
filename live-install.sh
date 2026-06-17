#!/usr/bin/env bash
# live-install — Provision a machine from ft-home on a NixOS live ISO.
#
# USAGE (interactive — process substitution keeps stdin available for prompts)
#   sh <(curl -fsSL https://raw.githubusercontent.com/track-prepped-68-corolla/ft-install/main/live-install.sh)
#
# STEPS
#   1. Clone ft-home to /tmp
#   2. Select target machine from machines/ inventory
#   3. Run nixos-facter → machines/<machine>/var/facter.json
#   4. Select install drive → patch ft.diskBtrfs.device in machine config
#   5. Run disko (destroy, format, mount at /mnt)
#   6. Copy repo to @src subvolume (/mnt/src/ft-home)
#   7. Write var/local/repoPath
#   8. Run nixos-install

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
ft_read() {
  local _var="$1" _msg="$2" _default="${3:-}"
  local _tty
  [ -t 0 ] && _tty="/dev/stdin" || _tty="/dev/tty"
  if [ -n "$_default" ]; then
    printf "${BOLD}  ? %s [%s]: ${NC}" "$_msg" "$_default" >/dev/tty 2>/dev/null \
      || printf "  ? %s [%s]: " "$_msg" "$_default"
  else
    printf "${BOLD}  ? %s: ${NC}" "$_msg" >/dev/tty 2>/dev/null \
      || printf "  ? %s: " "$_msg"
  fi
  local _reply
  read -r _reply < "$_tty"
  [ -z "$_reply" ] && [ -n "$_default" ] && _reply="$_default"
  printf -v "$_var" '%s' "$_reply"
}

run_git() {
  if command -v git >/dev/null 2>&1; then
    git "$@"
  else
    nix run nixpkgs#git -- "$@"
  fi
}

export NIX_CONFIG="extra-experimental-features = nix-command flakes"

FT_HOME_REPO="https://github.com/track-prepped-68-corolla/ft-home.git"
TEMP_REPO="/tmp/ft-home-install"
MOUNT_ROOT="/mnt"
SRC_MOUNT="${MOUNT_ROOT}/src"
REPO_NAME="ft-home"
REPO_DEST="${SRC_MOUNT}/${REPO_NAME}"
RUNTIME_REPO_PATH="/src/${REPO_NAME}"

printf "\n${BOLD}ft-home live ISO installer${NC}\n"

# ── 1. Clone ft-home ───────────────────────────────────────────────────────────
step "Clone ft-home"

if [ -d "${TEMP_REPO}/.git" ]; then
  warn "${TEMP_REPO} already exists — reusing."
else
  info "Cloning ft-home to ${TEMP_REPO} ..."
  run_git clone "${FT_HOME_REPO}" "${TEMP_REPO}"
fi

# ── 2. Select machine ──────────────────────────────────────────────────────────
step "Select machine"

mapfile -t MACHINES < <(
  find "${TEMP_REPO}/machines" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' \
    | grep -v '^live-iso$' \
    | sort
)

[ "${#MACHINES[@]}" -eq 0 ] && die "No machines found in ${TEMP_REPO}/machines"

printf "\nAvailable machines:\n\n"
for i in "${!MACHINES[@]}"; do
  printf "  ${BOLD}%d)${NC} %s\n" "$((i+1))" "${MACHINES[$i]}"
done
printf "\n"

ft_read machine_input "Select machine (number or name)"

if [[ "${machine_input}" =~ ^[0-9]+$ ]]; then
  idx=$(( machine_input - 1 ))
  (( idx >= 0 && idx < ${#MACHINES[@]} )) \
    || die "Invalid selection: ${machine_input}"
  MACHINE="${MACHINES[$idx]}"
else
  MACHINE="${machine_input}"
  found=0
  for m in "${MACHINES[@]}"; do [ "$m" = "$MACHINE" ] && found=1; done
  [ "${found}" -eq 1 ] || die "Machine not found: ${MACHINE}"
fi

info "Machine: ${MACHINE}"

# ── 3. Run nixos-facter ────────────────────────────────────────────────────────
step "Hardware detection"

FACTER_DIR="${TEMP_REPO}/machines/${MACHINE}/var"
FACTER_OUT="${FACTER_DIR}/facter.json"

mkdir -p "${FACTER_DIR}"
[ -f "${FACTER_OUT}" ] && warn "facter.json already exists — overwriting."

info "Running nixos-facter ..."
nix run --quiet github:numtide/nixos-facter -- -o "${FACTER_OUT}"
info "Hardware facts written to machines/${MACHINE}/var/facter.json"

# ── 4. Select install drive ────────────────────────────────────────────────────
step "Select install drive"

mapfile -t DRIVES < <(lsblk -d -o NAME -n | grep -Ev '^(loop|sr)')

[ "${#DRIVES[@]}" -eq 0 ] && die "No suitable block devices found."

# Read existing device from machine config if present.
CURRENT_DEVICE="$(grep -oP '(?<=ft\.diskBtrfs\.device = ")[^"]+'  \
  "${TEMP_REPO}/machines/${MACHINE}/default.nix" 2>/dev/null || true)"

printf "\nAvailable drives:\n\n"
for i in "${!DRIVES[@]}"; do
  meta="$(lsblk -d -o SIZE,MODEL -n "/dev/${DRIVES[$i]}" 2>/dev/null \
    | sed 's/  */ /g; s/^ //; s/ $//')"
  printf "  ${BOLD}%d)${NC} /dev/%-12s  %s\n" "$((i+1))" "${DRIVES[$i]}" "${meta}"
done
printf "\n"

DEFAULT_DRIVE="${CURRENT_DEVICE:-/dev/${DRIVES[0]}}"
ft_read drive_input "Select drive (number or /dev/... path)" "${DEFAULT_DRIVE}"

if [[ "${drive_input}" =~ ^[0-9]+$ ]]; then
  idx=$(( drive_input - 1 ))
  (( idx >= 0 && idx < ${#DRIVES[@]} )) \
    || die "Invalid drive selection: ${drive_input}"
  INSTALL_DRIVE="/dev/${DRIVES[$idx]}"
elif [[ "${drive_input}" == /dev/* ]]; then
  INSTALL_DRIVE="${drive_input}"
else
  die "Invalid drive: '${drive_input}' (enter a number or a /dev/... path)"
fi

info "Install drive: ${INSTALL_DRIVE}"

warn "ALL DATA ON ${INSTALL_DRIVE} WILL BE ERASED."
ft_read confirm "Type YES to confirm"
[ "${confirm}" = "YES" ] || die "Aborted."

# Update ft.diskBtrfs.device in the machine config so disko and nixos-install
# both see the chosen device. Changes are local to the temp clone.
MACH_NIX="${TEMP_REPO}/machines/${MACHINE}/default.nix"
if grep -q 'ft\.diskBtrfs\.device' "${MACH_NIX}"; then
  sed -i "s|ft\.diskBtrfs\.device = \"[^\"]*\"|ft.diskBtrfs.device = \"${INSTALL_DRIVE}\"|g" \
    "${MACH_NIX}"
  info "Updated ft.diskBtrfs.device = \"${INSTALL_DRIVE}\""
else
  warn "ft.diskBtrfs.device not found in machines/${MACHINE}/default.nix"
  warn "Ensure ft.diskBtrfs.enable = true and ft.diskBtrfs.device are present, then re-run."
  die "Cannot proceed without a disko disk layout."
fi

# ── 5. Provision disk (disko) ──────────────────────────────────────────────────
step "Disk provisioning (disko)"

info "Partitioning ${INSTALL_DRIVE} for ${MACHINE} ..."
nix run github:nix-community/disko -- \
  --mode disko \
  --flake "${TEMP_REPO}#${MACHINE}"

[ -d "${SRC_MOUNT}" ] \
  || die "@src not mounted at ${SRC_MOUNT} — check ft.diskBtrfs.enable in ${MACHINE}'s config."

info "Disk provisioned and mounted at ${MOUNT_ROOT}."

# ── 6. Copy repo to @src ───────────────────────────────────────────────────────
step "Install config repo to @src"

if [ -d "${REPO_DEST}" ]; then
  warn "${REPO_DEST} exists — removing."
  rm -rf "${REPO_DEST}"
fi

info "Copying ft-home to ${REPO_DEST} ..."
cp -a "${TEMP_REPO}" "${REPO_DEST}"
run_git -C "${REPO_DEST}" remote set-url origin "${FT_HOME_REPO}"
info "Git remote reset to ${FT_HOME_REPO}"

# ── 7. Write repoPath ──────────────────────────────────────────────────────────
step "Write var/local/repoPath"

mkdir -p "${REPO_DEST}/var/local"
printf '%s' "${RUNTIME_REPO_PATH}" > "${REPO_DEST}/var/local/repoPath"
info "repoPath = ${RUNTIME_REPO_PATH}"

# ── 8. Install NixOS ───────────────────────────────────────────────────────────
step "NixOS installation"

info "Running nixos-install — this may take a while ..."
nixos-install --no-root-passwd --flake "${REPO_DEST}#${MACHINE}"

# ── Done ───────────────────────────────────────────────────────────────────────
step "Done"
printf "\n"
info "Machine ${MACHINE} installed successfully."
printf "\n"
printf "  Config repo:  %s  (runtime path after reboot)\n" "${RUNTIME_REPO_PATH}"
printf "\n"
printf "After first boot:\n"
printf "  1. Review what changed:\n"
printf "       git -C %s diff HEAD\n" "${RUNTIME_REPO_PATH}"
printf "  2. Commit and push facter.json and device settings:\n"
printf "       git -C %s add machines/%s/\n" "${RUNTIME_REPO_PATH}" "${MACHINE}"
printf "       git -C %s commit -m 'provision: %s'\n" "${RUNTIME_REPO_PATH}" "${MACHINE}"
printf "       git -C %s push\n" "${RUNTIME_REPO_PATH}"
printf "\n"
