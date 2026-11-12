{
  config,
  lib,
  pkgs,
  ...
}:

# Assemble the ARM-TF FIP (Firmware Image Package) that the MT7988 BL2 loads,
# and expose the self-built BL2 that goes with it.
#
# BOOT CHAIN THIS FEEDS
# ---------------------
#   MTK BootROM -> BL2 (raw SD sector 34, built by ./atf.nix)
#     -> BL2 reads the GPT, finds the partition NAMED `fip`
#     -> loads BL31 (EL3 monitor) + BL33 (U-Boot) out of that FIP
#     -> U-Boot -> EFI/BOOT/BOOTAA64.EFI -> systemd-boot -> NixOS generations
#
# The FIP is a flat container: a header plus BL31/BL33 entries carrying
# offset+size+uuid.  It is assembled with ARM-TF's own `fiptool`, built from the
# same pinned source tree as BL31, so the container format can never drift from
# the BL2 that parses it.
#
# The board's BL2 does NOT verify FIP signatures: TRUSTED_BOARD_BOOT is off in
# ./atf.nix and the retail board ships with eFuses unblown.  So no key is
# involved and `fiptool create --align 16` is enough.  OpenWrt assembles its
# u-boot.fip the same way, with no signing step.
let
  cfg = config.hardware.bananapi.bpi-r4-pro;

  # `fiptool` from the same source as BL2/BL31.  This is a HOST tool: it runs on
  # the build machine and never on the board.
  fiptool = pkgs.stdenv.mkDerivation {
    pname = "fiptool-mt7988";
    version = cfg.atfPackage.version;

    src = cfg.atfPackage.atfSource;

    nativeBuildInputs = [ pkgs.openssl ];
    buildInputs = [ pkgs.openssl ];

    buildPhase = ''
      runHook preBuild
      make -C tools/fiptool fiptool
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm755 tools/fiptool/fiptool $out/bin/fiptool
      runHook postInstall
    '';

    dontStrip = true;
  };
in
{
  config = lib.mkIf (cfg.enable && cfg.buildFirmware) {
    # BL2 is the SD preloader and goes to RAW SECTOR 34 of the card: it is not a
    # partition and not a file, so no NixOS partition layout can place it -- the
    # image writer dd's it at seek=34.
    system.build.bpiR4ProBl2 = "${cfg.atfPackage}/bl2.img";

    system.build.bpiR4ProFip =
      pkgs.runCommand "bpi-r4-pro-fip.bin"
        {
          nativeBuildInputs = [ fiptool ];
          bl31 = "${cfg.atfPackage}/bl31.bin";
          bl33 = "${cfg.ubootPackage}/u-boot.bin";
        }
        ''
          # fiptool names the slots by their ARM-TF role, not by BL number:
          # BL31 (EL3 monitor) is `--soc-fw`, BL33 (U-Boot) is `--nt-fw`.
          fiptool create \
            --align 16 \
            --soc-fw "$bl31" \
            --nt-fw "$bl33" \
            "$out"

          # A malformed FIP is a board that only comes back by re-imaging the
          # card, so assert the contents here instead of finding out on the
          # serial console.
          fiptool info "$out" > /dev/null
          fiptool info "$out"
          if ! fiptool info "$out" | grep -qi 'SOC_FW\|BL31'; then
            echo "ERROR: BL31 missing from the FIP" >&2
            exit 1
          fi
          if ! fiptool info "$out" | grep -qi 'NT_FW\|BL33'; then
            echo "ERROR: BL33 (U-Boot) missing from the FIP" >&2
            exit 1
          fi
        '';

    # Keep the boot chain in the closure so a broken BL2/FIP fails the build
    # rather than the board.
    system.extraDependencies = [ config.system.build.bpiR4ProFip ];
  };
}
