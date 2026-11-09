# Banana Pi BPI-R4 Pro (MediaTek MT7988A)

NixOS support for the [Banana Pi BPI-R4 Pro](https://www.banana-pi.org/) router
board, built around the MediaTek MT7988A SoC (4× Cortex-A73, aarch64).

> **This lives in the `esp0xdeadbeef/nixos-hardware` fork** because upstream
> nixos-hardware has no MT7988/BPI-R4 Pro support yet. Once it does, the module
> can be proposed upstream as `bananapi/bpi-r4-pro`.

## Hardware (4E variant)

| Component | Detail |
| --------- | ------ |
| SoC | MediaTek MT7988A (4× Cortex-A73, aarch64) |
| Switch | MT7988 internal GSW + MaxLinear MxL86252 (10G) |
| Network | 1× 1G RJ45 (internal switch port 0), 4× 2.5G RJ45 (MxL86252), 1× 10G SFP+ LAN, 1× 2.5G RJ45 / 10G SFP+ WAN combo |
| Wi-Fi | MT7996 (optional, host AP) |
| Storage | microSD (boot chain), optional NVMe (root) |
| Firmware | vendor OpenWrt U-Boot (BL2 + ARM-TF FIP), no EFI |

## Why a patched kernel

Mainline `mtk_eth_soc` has **no USXGMII/SerDes support**, so the on-board 10G
switch (MxL86252) CPU conduit and the SFP+ cages cannot come up: the 10G
WAN/LAN is simply unsupported on mainline. The module therefore builds
nixpkgs' `linux_6_18` with the OpenWrt MT7988 networking delta (mtk_eth_soc
USXGMII + DSA mxl862xx + PCS mtk-usxgmii/lynxi), plus the AS21010 10G PHY and
TX-timeout recovery fixes (see `patches/`, GPL-2.0, via the
`ly4096x/BananaPi-R4-Pro-8X-OS` tree).

The board DTS itself only landed upstream in Linux 6.19, and its dtsi does not
compile against the 6.18 `mt7988a.dtsi`. This module therefore ships a
self-contained, resolved DTS (`dtb/mt7988a-bananapi-bpi-r4-pro-4e-sd.dts`) and
compiles it with `dtc` instead of building it from the kernel source.

## Usage

```nix
{
  imports = [
    nixos-hardware.nixosModules.bananapi-bpi-r4-pro
    # The board boots a raw FIT out of the `production` GPT partition; these two
    # modules produce it and write the U-Boot env that carries the bootargs.
    (nixos-hardware + "/bananapi/bpi-r4-pro/fit.nix")
    (nixos-hardware + "/bananapi/bpi-r4-pro/uboot-env.nix")
  ];

  hardware.bananapi.bpi-r4-pro.enable = true;

  # The board does not own its bootloader (vendor U-Boot loads the FIT), so keep
  # NixOS off the ESP. The module already disables grub/systemd-boot.
}
```

The module exposes:

- `hardware.bananapi.bpi-r4-pro.enable` — board support (this is the only
  mandatory switch).
- `hardware.bananapi.bpi-r4-pro.extraKernelParams` — extra kernel parameters
  appended to both the FIT bootargs and the U-Boot env.
- `hardware.bananapi.bpi-r4-pro.kernelCheck` (default `true`) — build-time
  guard that fails if the kernel loses the MT7988 ethernet + DSA drivers.
- `hardware.bananapi.bpi-r4-pro.fitSync` (default `true`) — reflash the
  `production` FIT on every boot so `nixos-rebuild boot` stays consistent.
- `hardware.bananapi.bpi-r4-pro.fitPartition` — the partition U-Boot reads the
  FIT from (default `/dev/disk/by-partlabel/production`).

Build artifacts: `config.system.build.bpiR4ProFit` (the FIT) and
`config.system.build.bpiR4ProUbootEnv` (the redundant U-Boot env image).

## Boot chain

The MT7988 boot chain finds its pieces **by name at fixed offsets** on the
microSD, so this layout is not a free choice:

```
cold power-on
  -> MTK BootROM -> BL2 (SD sector 34)
  -> BL2 reads the GPT and loads the ARM-TF FIP from the partition NAMED "fip"
     (if absent: "Partition 'fip' not found" -> "System halt!")
  -> BL31 + BL33 / OpenWrt U-Boot
  -> bootcmd = run boot_sdmmc
     boot_sdmmc = run boot_production ; run boot_recovery
     boot_production = ... && bootm $loadaddr#$bootconf#$bootconf_sd#$bootconf_extra
     sdmmc_read_production: read the FIT raw from offset 0 of the `production`
       partition
  -> NixOS (console ttyS0)
```

So the card must carry a GPT with `fip` (for BL2) and `production` (for
U-Boot). `sd-image.nix` lays out the vendor geometry:

| # | name | start (sector) | size (sectors) | note |
| - | ---- | -------------- | -------------- | ---- |
| 1 | bl2 | 34 | 8158 | BootROM/BL2 preloader |
| 2 | ubootenv | 8192 | 1024 | U-Boot env (bootargs) |
| 3 | factory | 9216 | 4096 | vendor calibration |
| 4 | fip | 13312 | 8192 | ARM-TF FIP (BL2 loads by name) |
| 5 | production | 327680 | 917504 | the raw NixOS FIT |
| 6 | nixos-root | (aligned) | fills | root filesystem |

`sd-image.nix` lays out the GPT, writes the U-Boot env into `ubootenv`, and
writes the FIT into `production`. It expects the vendor **bl2/fip** blobs to be
supplied from a stock OpenWrt SD image (this module does not ship the vendor
firmware blobs): flash a stock OpenWrt card first, then write this image's
`production` + `ubootenv` regions, or write the whole card from an image whose
firmware regions you have filled.

## `init=` and `root=`

Two details are load-bearing on this board and are already handled by
`fit.nix` / `uboot-env.nix`:

- `init=/nix/var/nix/profiles/system/init` is **mandatory** — NixOS's systemd
  initrd discovers the system closure only from `init=` on the kernel command
  line.
- `root=fstab` (not a `root=` device) — with a systemd initrd, `fileSystems."/"`
  already carries `x-initrd.mount`, so `systemd-fstab-generator` creates
  `sysroot.mount` from it. Passing a device as well makes it try to create
  `sysroot.mount` twice and bail out of generating the rest, so any
  `fsNeededForBoot` mount (e.g. `/persist`) never mounts.

`pci=pcie_bus_perf` is required for the NVMe to enumerate (mtk-pcie-gen3 fails
link training without it), and `clk_ignore_unused` / `pd_ignore_unused` keep the
MT7988 net driver's clock/power blocks from being gated before it probes.

## Status

Working (validated on the 4E board):

- boot to NixOS over the vendor U-Boot FIT, serial console (`ttyS0`)
- internal-switch 1G jack, MxL86252 2.5G jacks, 10G SFP+ via the patched kernel
- NVMe root (with `pci=pcie_bus_perf`)

Known issues:

- The `-iphy` overlay config is mapped to the resolved DTB; per-port 10G PHY
  tuning is out of scope here.
- 10G SFP+ link behaviour depends on the module in the cage.
