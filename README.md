# Umbriel & Noctalia Debian installer

Builds and installs [Umbriel](https://github.com/noctalia-dev/umbriel) (a
Wayland compositor) and [Noctalia](https://github.com/noctalia-dev/noctalia)
v5 (a desktop shell) from **pinned source revisions** on **Debian 13 (Trixie)
amd64**, into `/usr/local`.

UmbrielFX is part of the Umbriel source tree and is built as part of the
compositor; it is not a separate install target.

## Pins

| Component | Revision | Notes |
|---|---|---|
| Umbriel | `76cede129dc3e86bfb1e3a0009829c06618c0fdb` | No upstream release tag; pinned to the verified commit |
| Noctalia | `c7b9197af77ff22bfb9a83c52a95643a1d90ca86` | `v5.1.0` |
| xwayland-satellite | `8d135d3b2854b30fd01ea6cd6c27e523dd50a839` | `v0.8.2`; optional X11 companion |
| libinput | `1.29.0` | Built from source; see [Dependency notes](#dependency-notes) |

These pins came from the effort's research tickets on the issue tracker; update
them deliberately, then re-run to rebuild.

## Usage

```sh
./install.sh --deps        # repositories + packages + libinput source build
./install.sh --umbriel     # build + install Umbriel (and optional satellite)
./install.sh --noctalia    # build + install Noctalia v5
./install.sh --all         # dependencies, Umbriel, Noctalia
./install.sh               # interactive menu
```

Run `./install.sh --help` for all options (`--configure`, `--no-satellite`,
`-y/--yes`).

The script runs the build steps as your user and elevates only APT operations
and the final install into `/usr/local`. Source clones live under
`~/.local/state/umbriel-noctalia-install/` and are **retained** for rebuilds
and inspection; logs are kept per run in `logs/`.

It never overwrites user configuration. Umbriel ships a packaged fallback
config; `--configure` writes a first-time `~/.config/umbriel/config.toml` that
autostarts Noctalia, only when no config already exists.

## What each operation does

**`--deps`**

1. Adds Debian `trixie-backports` (needed for `wayland-protocols >= 1.47`) and
   the first-party-referenced [Noctalia APT
   repository](https://pkg.noctalia.dev) (backports of wlroots 0.20, Wayland
   1.25, libdrm, xkbcommon).
2. Installs the full build dependency set for Noctalia and Umbriel, plus
   runtime companions (`pipewire`, `wireplumber`, `xdg-desktop-portal`,
   `xdg-desktop-portal-umbriel`, `xwayland`, fonts).
3. Builds **libinput 1.29.0** from source into `/usr/local` — see below.

**`--umbriel`** — Meson release build (`-Dtests=disabled`) configured for the
`/usr/local` prefix, compiled as the invoking user, installed with `sudo
meson install`. This installs the compositor, its `start-umbriel` launcher,
the `umbriel.desktop` wayland-session entry, systemd user units, and the
packaged fallback config. Also builds the optional `xwayland-satellite`
companion for X11 application support (skip with `--no-satellite`).

**`--noctalia`** — Meson release build with upstream's recommended flags
(`-Dnative_optimizations=false -Djemalloc=auto`), installed to `/usr/local`.
Meson owns the full install set: binary, the mandatory assets tree, desktop
entry, and icon.

After `--all`, select the **Umbriel** entry from your display manager's session
menu. Noctalia must be in Umbriel's `[general] autostart` (`--configure` writes
that for you when no config exists).

## Dependency notes

- **Noctalia** needs `wayland-protocols >= 1.45` (the `ext-background-effect`
  protocol is used unconditionally). Trixie stable ships 1.44, so the
  backported 1.47/1.49 package is installed explicitly.
- **Umbriel** needs wlroots `>= 0.20.1, < 0.21`, Wayland `>= 1.24`,
  wayland-protocols `>= 1.47`, libdrm `>= 2.4.129` and xkbcommon `>= 1.8` — all
  provided by the Noctalia repo's `trixie-backports` suite.
- **libinput**: the pinned Umbriel uses the const-correct
  `libinput_config_accel_set_points()` API introduced in libinput 1.29.
  Neither Debian 13 nor the referenced repos ship it, so the script builds
  `1.29.0` from source. This is the known gap from the research tickets;
  raising the Umbriel Meson floor upstream would remove it.

## Testing

```sh
./tests/run_tests.sh
```

The harness exercises option parsing behavior (not string-sniffing), and
checks the script passes `bash -n`, is executable, and has no CRLF line
endings. A full clean-system run must be validated on a real Debian 13 amd64
host.