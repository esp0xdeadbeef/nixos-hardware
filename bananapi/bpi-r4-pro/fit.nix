{
  config,
  lib,
  pkgs,
  ...
}:

# Build the NixOS FIT image (.itb) that the board's stock OpenWrt U-Boot boots
# directly, and keep it in sync with the running generation.
#
# This is the format the vendor env expects, verbatim from the FIP blob:
#
#   boot_production       = ... bootm $loadaddr#$bootconf#$bootconf_sd#$bootconf_extra
#   bootconf              = config-mt7988a-bananapi-bpi-r4-pro-4e
#   bootconf_sd           = mt7988a-bananapi-bpi-r4-pro-4e-sd
#   bootconf_extra        = mt7988a-bananapi-bpi-r4-pro-4e-iphy
#   sdmmc_read_production = part start mmc 0 production ... mmc read $loadaddr 0x100 ...
#   loadaddr              = 0x50000000
#
# So U-Boot loads the whole FIT to 0x50000000, then `bootm`s the *default*
# configuration and applies the overlays named by $bootconf_sd/$bootconf_extra.
# `bootm` on a FIT address (not a filename) uses the FIT's DEFAULT configuration
# and applies the listed overlays.  Our configurations therefore must (a) have
# the same names U-Boot asks for, and (b) the base config must carry kernel +
# fdt + ramdisk, while the two overlay configs only carry fdt.
let
  cfg = config.hardware.bananapi.bpi-r4-pro;

  # Our resolved board DTB (base + SD overlay), see ./default.nix.
  # hardware.deviceTree.name = "mediatek/mt7988a-...-sd.dtb", and dtbSource lays
  # it out as <dtbSource>/mediatek/...  -> join to the full path directly.
  dtbFile = "${config.hardware.deviceTree.package}/${config.hardware.deviceTree.name}";

  # The implicit device-tree overlays U-Boot asks for by these names.  We hand
  # it pre-resolved DTBs and expose them under the names it requests so `bootm`
  # with $bootconf_sd/$bootconf_extra finds them.
  dtbSd = dtbFile;
  # The "iphy" overlay is out of scope (10G PHYs stay dark by default); map it
  # to the same resolved DTB so the requested config name exists and applies
  # cleanly.
  dtbIphy = dtbFile;

  kernelImage = "${config.system.build.kernel}/${config.system.boot.loader.kernelFile}";
  initrd = "${config.system.build.initialRamdisk}/initrd";

  # Bootargs baked into the FIT's /chosen.  U-Boot's image_setup_libfdt() always
  # overwrites /chosen/bootargs with env_get("bootargs"), so this is advisory
  # when booting via the vendor env (./uboot-env.nix writes the real one) but
  # keeps the FIT self-describing for a direct `bootm`.
  #
  # `init=` is MANDATORY: NixOS's systemd initrd discovers the system closure
  # ONLY from the `init=` kernel parameter.  `pci=pcie_bus_perf` is REQUIRED for
  # the NVMe to enumerate (mtk-pcie-gen3 fails link training without it).
  # clk/pd_ignore_unused are required (see ./default.nix).
  #
  # It must NOT pin init= to a specific toplevel: after an on-board rebuild this
  # would silently go stale.  Use the stable profile path.
  bootargs = lib.concatStringsSep " " (
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
  );

  itsFile = pkgs.writeText "bpi-r4-pro-4e.its" ''
    /dts-v1/;

    / {
      description = "NixOS for BPI-R4 Pro 4E";
      #address-cells = <1>;

      images {
        /* Addresses mirror the stock OpenWrt FIT (kernel 0x46000000, fdt
           0x45f00000): U-Boot loads the whole FIT at loadaddr=0x50000000 and
           then relocates these images, so they must not overlap that region. */
        kernel-1 {
          description = "NixOS ARM64 Linux";
          data = /incbin/("${kernelImage}");
          type = "kernel";
          arch = "arm64";
          os = "linux";
          compression = "none";
          load = <0x46000000>;
          entry = <0x46000000>;
          hash-1 { algo = "sha256"; };
        };

        fdt-1 {
          description = "BPI-R4 Pro 4E device tree";
          data = /incbin/("${dtbSd}");
          type = "flat_dt";
          arch = "arm64";
          compression = "none";
          load = <0x45f00000>;
          hash-1 { algo = "sha256"; };
        };

        /* Overlay configs requested by $bootconf_sd / $bootconf_extra.  Ship
           the already-resolved DTB under both so the requested configurations
           exist. */
        fdt-2 {
          description = "BPI-R4 Pro 4E SD (resolved)";
          data = /incbin/("${dtbSd}");
          type = "flat_dt";
          arch = "arm64";
          compression = "none";
          load = <0x45f00000>;
          hash-1 { algo = "sha256"; };
        };

        fdt-3 {
          description = "BPI-R4 Pro 4E iphy (resolved)";
          data = /incbin/("${dtbIphy}");
          type = "flat_dt";
          arch = "arm64";
          compression = "none";
          load = <0x45f00000>;
          hash-1 { algo = "sha256"; };
        };

        ramdisk-1 {
          description = "NixOS initrd";
          data = /incbin/("${initrd}");
          type = "ramdisk";
          arch = "arm64";
          os = "linux";
          compression = "none";
          load = <0x4a000000>;
          hash-1 { algo = "sha256"; };
        };
      };

      configurations {
        default = "config-mt7988a-bananapi-bpi-r4-pro-4e";

        /* Base config: U-Boot `bootm`s this one; it brings kernel+fdt+initrd. */
        config-mt7988a-bananapi-bpi-r4-pro-4e {
          description = "NixOS BPI-R4 Pro 4E";
          kernel = "kernel-1";
          fdt = "fdt-1";
          ramdisk = "ramdisk-1";
        };

        /* Overlay configs requested by $bootconf_sd / $bootconf_extra.
           `bootm <addr>#<cfg>#<sd>#<iphy>` applies these on top. */
        mt7988a-bananapi-bpi-r4-pro-4e-sd {
          description = "BPI-R4 Pro 4E SD overlay";
          fdt = "fdt-2";
        };

        mt7988a-bananapi-bpi-r4-pro-4e-iphy {
          description = "BPI-R4 Pro 4E iphy overlay";
          fdt = "fdt-3";
        };
      };

      /* Override U-Boot's own bootargs (its stock env has root=/dev/fit0, which
         would make NixOS stage-1 wait forever -> watchdog reset -> loop). */
      chosen {
        bootargs = "${bootargs}";
      };
    };
  '';
in
{
  options.hardware.bananapi.bpi-r4-pro = {
    fitPartition = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-partlabel/production";
      description = ''
        The GPT partition U-Boot reads the raw FIT from.  The fit-sync unit
        reflashes this whenever the current generation's FIT differs from what
        is on the card.
      '';
    };

    fitSync = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Reflash the production FIT to match the current generation on every
        boot, idempotently.  The board boots a STATIC FIT: a NixOS generation
        change does NOT rewrite it, so the running kernel keeps its old build
        while `kernel-modules` move on, and drivers then fail to load.  Keeping
        the FIT in sync makes `nixos-rebuild boot` safe.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    # Expose the FIT as a build artifact.  mkimage shells out to dtc to compile
    # the .its, so both ubootTools and dtc must be on PATH.
    system.build.bpiR4ProFit =
      pkgs.runCommand "nixos-bpi-r4-pro-4e.itb"
        {
          nativeBuildInputs = [
            pkgs.ubootTools
            pkgs.dtc
          ];
        }
        ''
          mkimage -f ${itsFile} "$out"
        '';

    # Keep the FIT in the system closure so fit-sync can reflash it, and make it
    # a build dependency so a broken FIT fails the build.
    system.extraDependencies = [ config.system.build.bpiR4ProFit ];

    systemd.services.bpi-r4-pro-fit-sync = lib.mkIf cfg.fitSync {
      description = "Reflash the BPI-R4 Pro production FIT to match the current generation";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = with pkgs; [
        coreutils
        util-linux
      ];
      script = ''
        set -euo pipefail

        fit=${config.system.build.bpiR4ProFit}
        part=${cfg.fitPartition}

        [ -b "$part" ] || { echo "no $part: skipping FIT sync"; exit 0; }
        [ -r "$fit" ] || { echo "FIT $fit missing: skipping"; exit 0; }

        fit_size=$(stat -c %s "$fit")
        part_size=$(blockdev --getsize64 "$part")
        if [ "$fit_size" -gt "$part_size" ]; then
          echo "FIT ($fit_size B) larger than production ($part_size B)" >&2
          exit 1
        fi

        want=$(sha256sum "$fit" | cut -d' ' -f1)
        have=$(head -c "$fit_size" "$part" | sha256sum | cut -d' ' -f1)

        if [ "$want" = "$have" ]; then
          echo "production FIT already matches the current generation"
          exit 0
        fi

        echo "reflashing production FIT (have $have -> want $want)"
        dd if="$fit" of="$part" bs=1M conv=fsync status=none
        sync
        echo "production FIT updated"
      '';
    };
  };
}
