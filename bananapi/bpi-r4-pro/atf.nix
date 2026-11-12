{
  lib,
  stdenv,
  fetchFromGitHub,
  ubootTools,
  dtc,
  python3,
  xz,
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
  makeFlags = [
    "PLAT=mt7988"
    "BOOT_DEVICE=${bootDevice}"
    "DRAM_USE_COMB=1"
    "USE_MKIMAGE=1"
    "MKIMAGE=mkimage"
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
