{
  config,
  lib,
  pkgs,
  ...
}:

# Write a real U-Boot environment into the board's `ubootenv` partition.
#
# U-Boot's image_setup_libfdt() ALWAYS overwrites /chosen/bootargs with
# env_get("bootargs") -- the FIT's own bootargs are ignored.  The vendor
# built-in default is
#
#   bootargs=console=ttyS0,115200n1 pci=pcie_bus_perf root=/dev/fit0 rootwait
#
# and `root=/dev/fit0` is OpenWrt's device, which does not exist for NixOS.
# Stage-1 then has no usable root= and no init=, and the boot dies right after
# "Run /init as init process".  So we write an env whose bootargs point at the
# NixOS root and the toplevel init.  Writing an env REPLACES the built-in one, so
# every variable the SD boot path needs is reproduced verbatim from the vendor
# FIP (only `bootargs` differs).
#
# `init=` is MANDATORY: the systemd initrd discovers the system closure ONLY
# from this parameter.  It points at the STABLE profile symlink, not a pinned
# /nix/store path, so a rebuild that moves /nix/var/nix/profiles/system is
# picked up on the next boot without rewriting this env.
#
# `root=fstab` (NOT root=PARTLABEL=...): with the systemd initrd,
# fileSystems."/" already carries `x-initrd.mount`, so systemd-fstab-generator
# creates sysroot.mount from that entry.  Passing a root= *device* as well makes
# it try to create sysroot.mount a second time, which makes it bail out of
# generating the rest -- so every fsNeededForBoot mount (e.g. /persist) fails to
# mount, and anything reading a key from there during initrd (sops-nix) breaks.
# `root=fstab` resolves the root from the fstab entry instead and leaves a single
# sysroot.mount.
let
  cfg = config.hardware.bananapi.bpi-r4-pro;

  envText = pkgs.writeText "bpi-r4-pro-uboot-env.txt" ''
    bootargs=${
      lib.concatStringsSep " " (
        [
          "console=ttyS0,115200n1"
          "pci=pcie_bus_perf"
          "clk_ignore_unused"
          "pd_ignore_unused"
          "root=fstab"
          "rootwait"
          "rw"
          "init=/nix/var/nix/profiles/system/init"
        ]
        ++ cfg.extraKernelParams
      )
    }
    bootdelay=2

    # --- SD boot path (verbatim from the vendor env) ---------------------------
    loadaddr=0x50000000
    part_default=production
    part_recovery=recovery
    bootconf=config-mt7988a-bananapi-bpi-r4-pro-4e
    bootconf_sd=mt7988a-bananapi-bpi-r4-pro-4e-sd
    bootconf_emmc=mt7988a-bananapi-bpi-r4-pro-4e-emmc
    bootconf_extra=mt7988a-bananapi-bpi-r4-pro-4e-iphy
    mmc_read_vol=mmc read $loadaddr $part_addr 0x100 && imszb $loadaddr image_size && test 0x$image_size -le 0x$part_size && mmc read $loadaddr 0x$part_addr 0x$image_size && setexpr filesize $image_size * 0x200
    sdmmc_read_production=part start mmc 0 $part_default part_addr && part size mmc 0 $part_default part_size && run mmc_read_vol
    sdmmc_read_recovery=part start mmc 0 $part_recovery part_addr && part size mmc 0 $part_recovery part_size && run mmc_read_vol
    boot_production=led $bootled_pwr on ; run sdmmc_read_production && bootm $loadaddr#$bootconf#$bootconf_sd#$bootconf_extra ; led $bootled_pwr off
    boot_recovery=led $bootled_rec on ; run sdmmc_read_recovery && bootm $loadaddr#$bootconf#$bootconf_emmc#$bootconf_extra ; led $bootled_rec off
    boot_sdmmc=run boot_production ; run boot_recovery
    # pstore/ramoops survives warm reboots; a stale panic would otherwise send us
    # to `boot_recovery` (which needs a `recovery` partition we do not ship).
    bootcmd=run boot_sdmmc

    # --- LEDs / menu (kept so the menu still works) ----------------------------
    bootled_pwr=green:status
    bootled_rec=blue:status
    bootmenu_default=0
    bootmenu_delay=0
    bootmenu_title=      ( ( ( OpenWrt ) ) )  [SD card]
    bootmenu_confirm_return=askenv - Press ENTER to return to menu ; bootmenu 60
    bootmenu_0=Run default boot command.=run bootcmd ; run bootmenu_confirm_return
    bootmenu_1=Boot production system from SD card.=run boot_production ; run bootmenu_confirm_return
    bootmenu_2=Reboot.=reset
    boot_first=bootmenu
    boot_default=run bootcmd
  '';
in
{
  config = lib.mkIf cfg.enable {
    # Redundant env: two 0x40000 copies (matches what the vendor U-Boot expects
    # and what the `ubootenv` partition is sized for).  `-r` marks it redundant.
    system.build.bpiR4ProUbootEnv =
      pkgs.runCommand "bpi-r4-pro-uboot-env.bin"
        {
          nativeBuildInputs = [ pkgs.ubootTools ];
        }
        ''
          mkenvimage -s 0x40000 -r -o "$out" ${envText}
        '';
  };
}
