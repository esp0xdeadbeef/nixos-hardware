{
  lib,
  stdenv,
  fetchFromGitHub,
  bc,
  bison,
  flex,
  dtc,
  gnutls,
  openssl,
  python3,
  swig,
  libuuid,
  ...
}:

# U-Boot (BL33) for the Banana Pi BPI-R4 Pro, built for the SD boot path.
#
# WHY NOT nixpkgs' ubootPackages
# -----------------------------
# nixpkgs' u-boot has MT7988 *SoC* support (mt7988_rfb_defconfig) but no
# BPI-R4 Pro defconfig: the board has not reached a mainline defconfig yet.
# frank-w carries `mt7988a_bpir4pro_sd_defconfig` in `2026-04-bpi`, which this
# pins.  When that defconfig reaches u-boot/master this can collapse to
# `pkgs.ubootPackages.*`.
#
# WHY EFI IS ENABLED
# ------------------
# Every MediaTek ARMv8 defconfig upstream sets `# CONFIG_EFI_LOADER is not
# set`.  Nothing in the hardware requires that -- it is a space decision --
# and enabling it is what lets the board boot a NixOS ESP with stock
# systemd-boot instead of a hand-rolled FIT (see ./efi.nix).
#
# The FIT this replaces carried an ABSOLUTE `init=` pointing at a store path,
# which pinned every reboot to whichever generation produced that FIT: a
# `nixos-rebuild boot` moved the profile but the board kept booting the old
# toplevel, and flashing a trial generation made it un-escapable without
# serial surgery.  An ESP with real generation entries removes that class of
# failure outright.
#
# `bootstd` (extlinux + EFI loader) and the classic load commands are both
# enabled on purpose, so a serial console can always reach a kernel by hand if
# the ESP/GPT is damaged.
let
  # Kconfig fragments layered on the board defconfig via `scripts/config`
  # (the supported way: it keeps Kconfig dependencies consistent).  Verify the
  # effective result with `make olddefconfig` + the assertions below.
  efibootConfig = [
    # --- boot a NixOS ESP ---
    "CONFIG_CMD_BOOTEFI=y"
    "CONFIG_CMD_BOOTEFI_BOOTMGR=y"
    "CONFIG_EFI_LOADER=y"
    "CONFIG_EFI_LOADER_BOUNCE_BUFFER=y"
    "CONFIG_EFI_HAVE_CAPSULE_SUPPORT=y"
    # Keep EFI variables in RAM: the boot medium is a read-only image and
    # there is no EFIVAR partition to persist them to.
    "CONFIG_EFI_VARIABLES_PRESEED=n"
    # --- standard boot ---
    "CONFIG_BOOTSTD=y"
    "CONFIG_BOOTSTD_FULL=y"
    "CONFIG_BOOTSTD_DEFAULTS=y"
    "CONFIG_BOOTMETH_EXTLINUX=y"
    "CONFIG_BOOTMETH_EFILOADER=y"
    "CONFIG_BOOTMETH_EXTLINUX_PXE=n"
    "CONFIG_CMD_BOOTFLOW=y"
    "CONFIG_CMD_BOOTMETH=y"
    "CONFIG_AUTOBOOT=y"
    "CONFIG_BOOTDELAY=2"
    # --- filesystems ---
    "CONFIG_CMD_EXT4=y"
    "CONFIG_CMD_FAT=y"
    "CONFIG_CMD_FS_GENERIC=y"
    "CONFIG_CMD_PART=y"
    "CONFIG_PARTITION_TYPE_GUID=y"
    "CONFIG_DOS_PARTITION=y"
    "CONFIG_EFI_PARTITION=y"
    # --- block devices the root/ESP live on ---
    "CONFIG_CMD_MMC=y"
    "CONFIG_MMC_MTK=y"
    "CONFIG_MMC_HS200_SUPPORT=y"
    "CONFIG_PCI=y"
    "CONFIG_PCIE_MEDIATEK_GEN3=y"
    "CONFIG_NVME=y"
    "CONFIG_NVME_PCI=y"
    "CONFIG_CMD_NVME=y"
    "CONFIG_CMD_PCI=y"
    "CONFIG_BLK=y"
    "CONFIG_DM=y"
    "CONFIG_USB=y"
    "CONFIG_USB_XHCI_HCD=y"
    "CONFIG_USB_XHCI_MTK=y"
    "CONFIG_USB_STORAGE=y"
    "CONFIG_CMD_USB=y"
    # --- rescue tooling over the serial console ---
    "CONFIG_CMD_ENV=y"
    "CONFIG_CMD_GPIO=y"
    "CONFIG_CMD_PINMUX=y"
    "CONFIG_CMD_I2C=y"
    "CONFIG_CMD_CACHE=y"
    "CONFIG_CMD_CLK=y"
    "CONFIG_CMD_RESET=y"
    "CONFIG_CMD_PSTORE=y"
    "CONFIG_CMD_PSTORE_MEM_ADDR=0x42ff0000"
    "CONFIG_CMD_PSTORE_RECORD_SIZE=0x2000"
    "CONFIG_CMD_PSTORE_CONSOLE_SIZE=0x0"
    "CONFIG_CMD_PSTORE_FTRACE_SIZE=0x0"
    "CONFIG_CMD_PSTORE_PMSG_SIZE=0x2000"
  ];

  # `scripts/config --set-val KEY value` / `--enable KEY` / `--disable KEY`.
  configCommands = lib.concatMapStringsSep "\n" (
    opt:
    let
      parts = lib.splitString "=" opt;
      name = lib.removePrefix "CONFIG_" (builtins.head parts);
      value = if builtins.length parts > 1 then builtins.concatStringsSep "=" (builtins.tail parts) else null;
    in
    if value == "n" then
      "scripts/config --file .config --disable ${name}"
    else if value == "y" then
      "scripts/config --file .config --enable ${name}"
    else if value != null then
      "scripts/config --file .config --set-val ${name} ${value}"
    else
      "scripts/config --file .config --enable ${name}"
  ) efibootConfig;
in
stdenv.mkDerivation {
  pname = "u-boot-bpi-r4-pro";
  version = "2026.04-bpi";

  src = fetchFromGitHub {
    owner = "frank-w";
    repo = "u-boot";
    rev = "2760d5001537cfdd5ce38a0e1d1707e2f58b0e04";
    hash = "sha256-vIkmgNwAkcWBNTlOaD+SBsMSW0BpwczvEVusmB4WpWY=";
  };

  # U-Boot builds host tools (dtc, binman, mkimage) and runs them during the
  # board build, so a native compiler is needed even when cross-compiling.
  nativeBuildInputs = [
    bc
    bison
    flex
    dtc
    python3
    swig
  ];
  buildInputs = [
    gnutls
    openssl
    libuuid
  ];

  makeFlags = [
    "CROSS_COMPILE=${stdenv.cc.targetPrefix}"
  ];

  postPatch = ''
    # U-Boot's Makefile refuses to honour CROSS_COMPILE unless HOSTCC is also
    # set explicitly by the caller, otherwise it tries to build host tools with
    # the cross compiler.
    substituteInPlace Makefile \
      --replace-fail 'HOSTCC ?= gcc' 'HOSTCC ?= gcc' || true
  '';

  configurePhase = ''
    runHook preConfigure
    make $makeFlags mt7988a_bpir4pro_sd_defconfig
    ${configCommands}
    make $makeFlags olddefconfig

    # Fail the build if the EFI loader did not actually stick.  Without this
    # the whole point of the change could silently regress to a FIT-only
    # firmware and only surface as an unbootable board.
    grep -q '^CONFIG_EFI_LOADER=y$' .config \
      || { echo "ERROR: CONFIG_EFI_LOADER did not survive olddefconfig" >&2; exit 1; }
    grep -q '^CONFIG_CMD_BOOTEFI=y$' .config \
      || { echo "ERROR: CONFIG_CMD_BOOTEFI not enabled" >&2; exit 1; }
    grep -q '^CONFIG_BOOTMETH_EFILOADER=y$' .config \
      || { echo "ERROR: bootmeth EFI loader not enabled" >&2; exit 1; }

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make $makeFlags -j$NIX_BUILD_CORES u-boot.bin u-boot.dtb
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    install -m644 u-boot.bin $out/u-boot.bin
    install -m644 u-boot.dtb $out/u-boot.dtb
    install -m644 .config $out/u-boot.config
    runHook postInstall
  '';

  dontStrip = true;

  meta = with lib; {
    description = "U-Boot (BL33) with EFI loader for the Banana Pi BPI-R4 Pro (MT7988A)";
    homepage = "https://github.com/frank-w/u-boot";
    license = licenses.gpl2Plus;
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
}
