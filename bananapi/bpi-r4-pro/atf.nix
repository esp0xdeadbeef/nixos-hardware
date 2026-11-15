{
  lib,
  stdenv,
  fetchFromGitHub,
  ubootTools,
  dtc,
  python3,
  xz,
  # DRAM init is the one part of BL2 that cannot be copied from BL31: it runs
  # before any memory exists.  MediaTek ships one config per DDR population, and
  # `DRAM_USE_COMB=1` ("detect at runtime from the combined table") is what
  # OpenWrt selects for trusted-firmware-a-mt7988-sdmmc-comb.
  #
  # Exposed as an argument because the bisect cannot otherwise separate this
  # from a FIP/BL31 problem: with our BL2 the board reset-loops at "Jump to BL"
  # and never prints a BL31 banner, while the VENDOR BL2 driving the same FIP
  # boots fine.  To test an alternative:
  #   pkgs.callPackage ./atf.nix { dramFlag = "DRAM_USE_DDR4=1"; }
  dramFlag ? "DRAM_USE_COMB=1",
  ...
}:

# MediaTek MT7988 ARM Trusted Firmware (BL2 preloader + BL31 monitor).
#
# WHY THIS IS NOT nixpkgs' arm-trusted-firmware
# ---------------------------------------------
# Upstream TF-A has NO mt7988 platform: `plat/mediatek/` there carries mt8188
# only.  MT7988 support lives exclusively in MediaTek's downstream ATF, which
# is the tree OpenWrt builds from.  This derivation pins the exact commit
# OpenWrt ships (package/boot/arm-trusted-firmware-mediatek, PROTO=git,
# PLAT=mt7988) so the boot chain is reproducible from a known-good source
# rather than from a vendored vendor blob.
#
# WHAT IT PRODUCES
# ----------------
#   bl2.img : the MT7988 SD preloader.  The BootROM loads it from RAW SECTOR 34
#             of the microSD -- it is not a partition and not a file, so
#             nothing in NixOS's partitioning can place it.  `mk-sd-image.sh`
#             dd's this at seek=34.
#   bl31.bin: the EL3 runtime monitor, packed into the FIP together with
#             U-Boot (BL33) by ./fip.nix.
#
# The boot-ROM header is applied with `mkimage -T mtk_image` (the same tool
# OpenWrt uses when USE_MKIMAGE=1).  Signing is deliberately NOT enabled:
# `TRUSTED_BOARD_BOOT` gates only signature *verification* of the FIP, and the
# retail board ships with eFuses unblown, so BL2 loads an unsigned FIP.  Signing
# would need an MBEDTLS_DIR and a key we do not have, and would make the boot
# chain depend on a secret that is not recoverable.
let
  # Board geometry: microSD, combo (LPDDR) DRAM -- the same BUILD_VARIANT
  # OpenWrt uses for `mt7988_bananapi_bpi-r4-sdmmc`
  # (trusted-firmware-a-mt7988-sdmmc-comb).
  bootDevice = "sdmmc";

  # The single source of truth for the ATF tree.  ./fip.nix reuses this exact
  # source to build `fiptool`, so the FIP container format can never drift from
  # the BL2 that parses it.
  atfSource = fetchFromGitHub {
    owner = "mtk-openwrt";
    repo = "arm-trusted-firmware";
    rev = "bacca82a8cac369470df052a9d801a0ceb9b74ca";
    hash = "sha256-n5D3styntdoKpVH+vpAfDkCciRJjCZf9ivrI9eEdyqw=";
  };
in
stdenv.mkDerivation (_finalAttrs: {
  pname = "arm-trusted-firmware-mt7988";
  version = "2024-01-17";

  src = atfSource;

  passthru = { inherit atfSource; };

  nativeBuildInputs = [
    ubootTools # mkimage -T mtk_image (the BL2 boot-ROM header)
    dtc
    (python3.withPackages (ps: [ ps.pyelftools ])) # fiptool/bl2 tools
    xz
  ];

  # OpenWrt passes CROSS_COMPILE and builds AArch64 from a 64-bit host directly.
  # Do the same here so the output is byte-comparable with theirs.
  #
  # These flags mirror TFA_MAKE_FLAGS in OpenWrt's
  # package/boot/arm-trusted-firmware-mediatek/Makefile for the
  # `mt7988-sdmmc-comb` variant -- the exact variant this board uses:
  #
  #   BOOT_DEVICE=$(BOOT_DEVICE)                       -> sdmmc
  #   USE_MKIMAGE=1 MKIMAGE=$(STAGING_DIR_HOST)/bin/mkimage
  #   $(if $(findstring ddr4,$(DDR_TYPE)),DRAM_USE_DDR4=1)
  #   $(if $(BOARD_QFN),BOARD_QFN=1,BOARD_BGA=1)       -> BOARD_BGA=1
  #   HAVE_DRAM_OBJ_FILE=yes
  #   $(if $(DRAM_USE_COMB),DRAM_USE_COMB=1)           -> set for *-comb
  #
  # BOARD_BGA and HAVE_DRAM_OBJ_FILE are passed UNCONDITIONALLY by OpenWrt;
  # they are not optional extras.  Omitting them changes which DRAM object gets
  # linked into BL2, which is the code path that runs between the BootROM and
  # BL31 -- and BL2 is what hands off to the BL31 that services PSCI
  # SYSTEM_RESET/SYSTEM_OFF.  Both a warm reboot and `shutdown now` hang on this
  # board, and both are PSCI SMCs into BL31, so the preloader is the first place
  # to make byte-comparable with a build that is known to work.
  makeFlags = [
    "PLAT=mt7988"
    "BOOT_DEVICE=${bootDevice}"
    dramFlag
    "USE_MKIMAGE=1"
    "MKIMAGE=mkimage"
    "BOARD_BGA=1"
    "HAVE_DRAM_OBJ_FILE=yes"
    "CROSS_COMPILE=${stdenv.cc.targetPrefix}"
    "all"
  ];

  enableParallelBuilding = true;

  # TF-A's build writes into its own build/ dir and shells out to python for
  # the tool wrappers; hardening flags would break its freestanding AArch64
  # objects (it passes -nostdinc and its own CC flags).
  hardeningDisable = [ "all" ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp build/mt7988/release/bl2.img $out/bl2.img
    cp build/mt7988/release/bl31.bin $out/bl31.bin
    runHook postInstall
  '';

  meta = with lib; {
    description = "MediaTek MT7988 ARM Trusted Firmware (BL2 + BL31) for the BPI-R4 Pro";
    homepage = "https://github.com/mtk-openwrt/arm-trusted-firmware";
    license = licenses.bsd3;
    maintainers = [ ];
    platforms = [
      "aarch64-linux"
      "x86_64-linux"
    ];
  };
})
