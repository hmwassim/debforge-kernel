# debforge-kernel

Rebuild Debian's newest backports kernel with a few responsiveness tweaks, as installable Debian packages.

```text
linux-source + Debian's config (from <release>-backports)
  + your patches in patches/
  + the OPTIONS in build.sh
  -> output/<version>/*.deb
```

## Usage

```bash
sudo ./build.sh                            # build, then print the install command
sudo ./build.sh --suffix=desktop --install # build as 7.2.6-desktop and install it
./build.sh --help
```

| Option | Meaning |
|---|---|
| `--suffix=NAME` | Added to the kernel release and package names (default `debforge`). Kernels with different suffixes install side by side. |
| `--install` | Install the image and headers packages after building. |

sudo is required, but it is only used for apt: installing missing build packages, refreshing the package lists and `--install`. Downloading, configuring and compiling run as the user who called sudo.

## Requirements

* Debian 13 (trixie) on x86_64
* the backports suite enabled:

  ```bash
  echo 'deb http://deb.debian.org/debian trixie-backports main' | sudo tee /etc/apt/sources.list.d/trixie-backports.list
  ```

Missing build packages are installed automatically.

## What changes

Everything stays as Debian ships it, except:

| Option | Debian | debforge-kernel |
|---|---|---|
| Timer frequency | 250 Hz | 1000 Hz |
| Rust support | on | off |
| Kernel panic screen | QR code | short message (the QR code needs Rust) |
| Module compression | xz | zstd (faster to load) |
| `teo` idle governor | not built | built (`menu` stays the default) |
| Console takeover | immediate | deferred until there is text (no flicker at boot) |
| IRQ time accounting | off | on (interrupt time isn't charged to the running task) |

Preemption is lazy and dynamic, as in Debian, so `preempt=full` on the kernel command line switches it without a rebuild. To try the `teo` idle governor, boot with `cpuidle.governor=teo`.

To change the options, edit the `OPTIONS` block at the top of `build.sh`. It uses the kernel's own config format:

```text
CONFIG_SOMETHING=y
CONFIG_VALUE=1000
# CONFIG_OTHER is not set
```

Every line is checked in the final `.config`, and the build stops if one did not survive.

## Patches

Drop `.patch` files into `patches/`, or into `patches/<series>/` (e.g. `patches/7.2/`) for patches that only apply to one kernel series. Those in `patches/` are applied first, then the series' own, each in name order with `patch -p1` on top of Debian's source. If a patch does not apply cleanly, the build stops.

`patches/7.2/` backports upstream's fix for kfunc BTF, which sched_ext (scx) schedulers need: resolve_btfids tags kfuncs itself instead of relying on pahole, as Linux 7.3 does.

## Output

* `output/<version>/`: `linux-image-<release>_amd64.deb` and `linux-headers-<release>_amd64.deb`, ready to upload as release assets
* `build/build.log`: the compile log
* `cache/`: downloaded Debian packages, reused between builds

Remove an installed kernel with:

```bash
sudo apt remove linux-image-7.2.6-debforge linux-headers-7.2.6-debforge
```

## Limitations

* The kernel is not signed for Secure Boot. With Secure Boot on, it will not boot unless you sign it yourself.
* Every run starts from a fresh source tree, so each build is a full compile.
