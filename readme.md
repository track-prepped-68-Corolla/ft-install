# ft-install

Bootstrap script for the fast-track-nix ecosystem on any Linux machine. It
wraps the Lix fork of the Determinate Systems Nix installer, then sets up one
of two starting points.

## Modes

| Flag    | Installs                                                        |
|---------|-----------------------------------------------------------------|
| `--emu` | Lix + Home Manager + the ft-emu emulation suite (any Linux distro) |
| `--nix` | Lix + a clone of `ft-template`, to start a NixOS configuration   |

Run without a flag to be asked which mode you want; `--help` lists the flags.

## Usage

Interactive (process substitution keeps stdin free for the prompts):

```sh
sh <(curl -fsSL https://raw.githubusercontent.com/track-prepped-68-corolla/ft-install/main/install.sh)
```

Non-interactive:

```sh
curl -fsSL https://raw.githubusercontent.com/track-prepped-68-corolla/ft-install/main/install.sh | sh -s -- --emu
curl -fsSL https://raw.githubusercontent.com/track-prepped-68-corolla/ft-install/main/install.sh | sh -s -- --nix
```
