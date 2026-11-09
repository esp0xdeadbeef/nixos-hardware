{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:

# SD-card image with the board's vendor GPT boot-chain geometry.
#
# The MT7988 boot chain finds its pieces BY NAME at FIXED offsets on the microSD,
# so this layout is not a free choice:
#
#   * The BootROM loads BL2 from raw sector 34 of mmc 0.
#   * BL2 (SD preloader) reads the GPT and searches for a partition named `fip`
#     (if absent it prints "Partition 'fip' not found" then "System halt!").
#   * U-Boot reads the NixOS FIT raw at offset 0 of the partition named
#     `production`.
#
# This module produces a bootable card whose root lives on the same card (the
# simplest self-contained image).  If you keep root on NVMe, use ./default.nix +
# ./fit.nix and write the card separately -- see the README.
#
# The bl2/fip FAT entries are written by the vendor SD image; this module lays
# out the GPT and the production FIT but expects bl2/fip to be supplied from a
# vendor image (see `vendorBootPartitions` below).  For a from-scratch card,
# flash a stock OpenWrt SD image first, then write this image's `production`
# partition and `ubootenv` partition over it.
let
  # Sector geometry, identical to the vendor GPT.
  #   name        start(sec)  size(sec)
  bl2Start = 34;
  bl2Size = 8158;
  ubootenvStart = 8192;
  ubootenvSize = 1024;
  factoryStart = 9216;
  factorySize = 4096;
  fipStart = 13312;
  fipSize = 8192;
  productionStart = 327680;
  productionSize = 917504;
in
{
  imports = [
    "${modulesPath}/profiles/base.nix"
    "${modulesPath}/installer/sd-card/sd-image.nix"
    ./default.nix
    ./fit.nix
    ./uboot-env.nix
  ];

  hardware.enableAllHardware = lib.mkForce false;

  # Root on the card's own btrfs partition.
  fileSystems."/" = lib.mkForce {
    device = "/dev/disk/by-partlabel/nixos-root";
    fsType = "btrfs";
  };

  image.fileName = "${config.image.baseName}-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}-bpi-r4-pro-4e.img";

  sdImage = {
    compressImage = true;

    # No ESP: the vendor U-Boot has no EFI path on this board.
    populateFirmwareCommands = "";
    populateRootCommands = "";

    # Lay out the vendor geometry, then write the FIT (+ env) into it.
    postBuildCommands = ''
      # Partition 2 of the sd-image base is `nixos-root` (the rootfs); read its
      # start/size so the vendor partitions can precede it.
      eval $(${pkgs.buildPackages.util-linux}/bin/partx $img -o START,SECTORS --nr 2 --pairs)
      ROOTFS_START=$START
      ROOTFS_SECTORS=$SECTORS

      truncate -s '+4M' $img

      ${pkgs.buildPackages.util-linux}/bin/sfdisk $img <<EOF
          label: gpt
          unit: sectors
          sector-size: 512
          first-lba: 256

          start=${toString bl2Start},        size=${toString bl2Size},        name="bl2",        type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=${toString ubootenvStart},   size=${toString ubootenvSize},   name="ubootenv",   type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=${toString factoryStart},    size=${toString factorySize},    name="factory",    type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=${toString fipStart},        size=${toString fipSize},        name="fip",        type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
          start=${toString productionStart}, size=${toString productionSize}, name="production", type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
          start=$ROOTFS_START, size=$ROOTFS_SECTORS, name="nixos-root", type=0FC63DAF-8483-4772-8E79-3D69D8477DE4
      EOF

      # U-Boot env (real bootargs), written to the start of `ubootenv`.
      ${pkgs.buildPackages.coreutils}/bin/dd \
        if=${config.system.build.bpiR4ProUbootEnv} \
        of=$img conv=notrunc bs=512 \
        seek=${toString ubootenvStart} status=none

      # The NixOS FIT, raw at offset 0 of `production`.
      ${pkgs.buildPackages.coreutils}/bin/dd \
        if=${config.system.build.bpiR4ProFit} \
        of=$img conv=notrunc bs=512 \
        seek=${toString productionStart} status=none
    '';
  };
}
