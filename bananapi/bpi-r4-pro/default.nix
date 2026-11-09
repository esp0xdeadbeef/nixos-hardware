{
  config,
  lib,
  pkgs,
  ...
}:

# Banana Pi BPI-R4 Pro (MediaTek MT7988A, aarch64).
#
# Board support only: device tree, console, kernel and boot-chain policy.  It
# deliberately does NOT own the root filesystem, users, or networking -- those
# belong to the consuming host.
#
# The 4E variant is the populated board used in this repo's fleet (s-nodus):
# a single 1G internal-switch jack, four 2.5G MxL86252 copper jacks, one 10G
# SFP+ LAN, one 2.5G RJ45 / 10G SFP+ WAN combo.  See ./dtb for the port map.
#
# Boot chain (the board's stock OpenWrt U-Boot, read verbatim from the vendor
# FIP blob):
#
#   cold power-on
#     -> MTK BootROM -> BL2 (SD sector 34)
#     -> BL2 reads the GPT and loads the ARM-TF FIP from the partition NAMED
#        "fip"  (if absent: "Partition 'fip' not found" -> "System halt!")
#     -> BL31 + BL33/U-Boot
#     -> bootcmd = run boot_sdmmc
#        boot_sdmmc = run boot_production ; run boot_recovery
#        boot_production = ... sdmmc_read_production && bootm $loadaddr#$bootconf#$bootconf_sd#$bootconf_extra
#        sdmmc_read_production: `part start mmc 0 production`, read the FIT raw
#          from offset 0 of that partition, `imszb` it, check size <= part_size
#     -> NixOS
#
# NixOS does NOT own the bootloader on this board: no systemd-boot, no EFI (the
# vendor U-Boot's default env contains no bootefi/BOOTAA64 path).  The FIT is
# produced by ./fit.nix and written into the `production` partition by
# ./sd-image.nix (or the fit-sync unit for upgrades).
let
  cfg = config.hardware.bananapi.bpi-r4-pro;
in
{
  imports = [ ./linux.nix ];

  options.hardware.bananapi.bpi-r4-pro = {
    enable = lib.mkEnableOption "Banana Pi BPI-R4 Pro (MT7988A) board support";

    extraKernelParams = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Extra kernel parameters appended to the board bootargs (both the FIT's
        /chosen bootargs and the U-Boot env written into the `ubootenv`
        partition).
      '';
    };

    kernelCheck = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Keep the MT7988 ethernet + DSA drivers in the build closure, so a
        nixpkgs/kernel bump cannot silently drop them.  Without them the board
        boots with no netdev at all, and the only way back in is the serial
        console.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # --- device tree ----------------------------------------------------
    # We ship a SELF-CONTAINED board DTS and compile it directly with dtc,
    # instead of building it from the kernel source.  Two reasons:
    #
    #   1. The board DTS only landed upstream in Linux 6.19, and we run the
    #      6.18 board kernel (./linux.nix) for its MT7988 USXGMII/SerDes +
    #      MxL86252 support -- so the kernel source has no 4E DTS.
    #   2. The mainline 6.19 board dtsi does not compile against the 6.18
    #      mt7988a.dtsi (symbol drift, e.g. ssusb0).  A resolved, self-contained
    #      DTS sidesteps all of that.
    #
    # Provenance of ./dtb/mt7988a-bananapi-bpi-r4-pro-4e-sd.dts: `dtc -I dtb -O
    # dts` of the resolved tree (mainline board dtsi + the lan-port-map fragment
    # + the mainline SD overlay) that already runs on the hardware, frozen into
    # one file.  It carries the board fixes: internal switch port 0 only,
    # MxL86252 in MAINLINE port numbering (copper 1..4, CPU 9, SFP 13), firmware
    # 1.0.85.
    hardware.deviceTree = {
      enable = lib.mkDefault true;
      name = lib.mkDefault "mediatek/mt7988a-bananapi-bpi-r4-pro-4e-sd.dtb";
      dtbSource = lib.mkDefault (
        pkgs.runCommand "bpi-r4-pro-dtbs"
          {
            nativeBuildInputs = [ pkgs.dtc ];
          }
          ''
            mkdir -p $out/mediatek
            dtc -I dts -O dtb -o "$out/mediatek/mt7988a-bananapi-bpi-r4-pro-4e-sd.dtb" \
              ${./dtb/mt7988a-bananapi-bpi-r4-pro-4e-sd.dts}
          ''
      );
    };

    # --- kernel build guard ---------------------------------------------
    # The headline cause of an unreachable board on this setup was kernel/module
    # DRIFT (the boot FIT carrying a different kernel than the generation's
    # `kernel-modules`; ./fit.nix keeps them in sync).  This guard is the
    # complementary check: it fails the build if the kernel's modules tree does
    # not carry the MT7988 ethernet + MT7530 DSA drivers at all.
    system.extraDependencies = lib.optional cfg.kernelCheck (
      pkgs.runCommand "bpi-r4-pro-kernel-mt7988-net-check"
        {
          nativeBuildInputs = [ pkgs.xz ];
          modules = config.boot.kernelPackages.kernel.modules;
        }
        ''
          found_eth=0
          found_dsa=0
          while IFS= read -r f; do
            case "$f" in
              */drivers/net/ethernet/mediatek/mtk_eth.ko*) found_eth=1 ;;
              */drivers/net/dsa/mt7530.ko*) found_dsa=1 ;;
            esac
          done < <(find "$modules" -type f -o -type l)
          if [ "$found_eth" != 1 ] || [ "$found_dsa" != 1 ]; then
            echo "ERROR: kernel modules tree lacks MT7988 ethernet/DSA drivers" >&2
            echo "  mtk_eth found: $found_eth  mt7530 found: $found_dsa" >&2
            echo "  modules: $modules" >&2
            exit 1
          fi
          touch "$out"
        ''
    );

    # --- console / bootargs ---------------------------------------------
    # ttyS0 @ 115200 8N1 (confirmed on a live boot).
    #
    # clk_ignore_unused / pd_ignore_unused: keep "unused" clocks and power
    # domains on.  On MT7988 the MTK net drivers probe late; with
    # clk_disable_unused/genpd having gated their block a register access
    # hangs the CPU (rcu_sched stall -> hard LOCKUP -> boot wedge).  These flags
    # prevent that gating.
    #
    # NOTE: the authoritative bootargs on this board come from the U-Boot env
    # (./uboot-env.nix); these kernelParams feed the FIT's /chosen/bootargs and
    # a direct `bootm` without the env.
    boot.kernelParams = lib.mkBefore [
      "console=ttyS0,115200n1"
      "clk_ignore_unused"
      "pd_ignore_unused"
    ];

    # `kernel.dmesg_restrict = 1` means an ordinary operator account gets ZERO
    # lines from dmesg, which is backwards for a board that is diagnosed over
    # ssh.
    boot.kernel.sysctl."kernel.dmesg_restrict" = lib.mkDefault 0;

    # The DT reserves only 64 KiB of ramoops at 0x42ff0000 and the pstore
    # CONSOLE backend fills it with ordinary console output, leaving no room for
    # the oops record itself (ENOSPC on a panic).  Drop the console backend to
    # keep the zone for dmesg/oops records.
    boot.extraModprobeConfig = lib.mkDefault "options ramoops console_size=0";

    # The serial console must ALWAYS exist: it is the only way onto this board
    # when the network is down, which happens regularly.
    #
    # `serial-getty@ttyS0` is normally instantiated by systemd-getty-generator
    # only when `console=ttyS0` appears on the KERNEL COMMAND LINE.  On this
    # board that command line comes from the U-Boot env, not from NixOS's
    # boot.kernelParams -- so if an env is flashed whose bootargs lack the
    # console argument, no serial getty is ever spawned and the board becomes
    # unreachable exactly when the console matters most.  Pulling the instance in
    # through getty.target makes it independent of the bootargs.
    systemd.targets.getty.wants = [ "serial-getty@ttyS0.service" ];

    # --- initrd ---------------------------------------------------------
    # NVMe root needs the mtk-pcie-gen3 host controller (built-in in the board
    # kernel); the SD fallback needs mmc host + the card filesystems.
    boot.initrd.availableKernelModules = [
      "mmc_block"
      "sd_mod"
      "nvme"
      "nvme_core"
      "usb_storage"
      "uas"
    ];

    # --- bootloader -----------------------------------------------------
    # NixOS does not own the bootloader: the vendor U-Boot loads the raw FIT
    # from the `production` partition (see ./fit.nix).  Disable every NixOS
    # bootloader so nothing writes an ESP we do not use.
    boot.loader.grub.enable = lib.mkForce false;
    boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
    boot.loader.systemd-boot.enable = lib.mkForce false;
    boot.loader.efi.canTouchEfiVariables = lib.mkForce false; # no EFI vars on this board
  };
}
