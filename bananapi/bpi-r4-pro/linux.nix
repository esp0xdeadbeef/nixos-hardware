{
  lib,
  pkgs,
  ...
}:

# Board kernel for the Banana Pi BPI-R4 Pro (MediaTek MT7988A).
#
# Why not just nixpkgs' mainline kernel: mainline's mtk_eth_soc has NO
# USXGMII/SerDes support, so the on-board 10G switch (MxL86252) CPU conduit and
# the SFP+ cages cannot come up -- the 10G WAN/LAN is simply unsupported on
# mainline.  The board DTS itself (mt7988a-bananapi-bpi-r4-pro-4e.dts) only
# landed upstream in Linux 6.19, and its dtsi does not compile against the 6.18
# mt7988a.dtsi, so we also ship a resolved, self-contained DTS (see ./default.nix
# and ./dtb/).
#
# We therefore build nixpkgs' linux_6_18 with the curated OpenWrt MT7988
# networking delta (mtk_eth_soc USXGMII + DSA mxl862xx + PCS mtk-usxgmii/lynxi)
# applied, rebased onto nixpkgs' 6.18.55 (see
# patches/openwrt-mt7988-net-6.18.55.patch, GPL-2.0, via the
# ly4096x/BananaPi-R4-Pro-8X-OS tree).
let
  # The patch set in ./patches is rebased onto linux 6.18.5.
  #
  # `pkgs.linux_6_18` is mainline.nix, a TRACKING kernel: its version comes from
  # kernels-org.json (branch = "6.18"), so it moves to a new point release
  # whenever nixpkgs is updated -- 6.18.62 at the time of writing.  The patch
  # then fails with
  #
  #   Hunk #6 FAILED at 142.   drivers/net/pcs/pcs-mtk-lynxi.c
  #
  # which surfaces far from the cause, as a failed btrfs-fs.img deep inside the
  # SD-image closure.
  #
  # Pin the base here.  mainline.nix applies `args.argsOverride` AFTER the
  # json-derived version/src, which is why this works and
  # `linux_6_18.override { version = ...; }` does not (verified: that produced
  # src linux-6.18.62.tar.xz regardless).
  #
  # Moving to a newer 6.18.x means rebasing the patch set and bumping
  # patchBase together -- they are one unit.
  patchBase = "6.18.55";
  # NOTE: this must be merged into ONE override below.  A second
  # `baseKernel.override { ... }` REPLACES argsOverride wholesale and silently
  # loses the pin (that is exactly how the version stayed at 6.18.62).
in
{
  boot.kernelPackages = lib.mkDefault (
    pkgs.linuxPackagesFor (
      pkgs.linux_6_18.override (prev: {
        # Pin the base kernel: linux_6_18 is mainline.nix and tracks 6.18.x
        # from kernels-org.json, so it drifts to a new point release whenever
        # nixpkgs moves.  mainline.nix applies argsOverride AFTER the
        # json-derived version/src, which is why this works and
        # `linux_6_18.override { version = ...; }` alone does not.
        argsOverride = {
          version = patchBase;
          modDirVersion = "${patchBase}.0";
          src = pkgs.fetchurl {
            url = "mirror://kernel/linux/kernel/v6.x/linux-${patchBase}.tar.xz";
            hash = "sha256-9BBjgGGhZcEvQquHHS8/zVJVFTWbX67ugJac/4RSTfk=";
          };
        };
        kernelPatches = (prev.kernelPatches or [ ]) ++ [
          {
            name = "openwrt-mt7988-net";
            patch = ./patches/openwrt-mt7988-net-6.18.55.patch;
          }
          # mt7530-mdio.c must match the delta's reworked mtk_pcs_lynxi_create()
          # signature (dev, fwnode, regmap, ana_rgc3), otherwise it is a real
          # incompatible-pointer/int-conversion bug on the lan5 SerDes PCS path.
          {
            name = "mt7530-pcs-lynxi-sig";
            patch = ./patches/980-mt7530-match-mtk-pcs-lynxi-create-signature.patch;
          }
          # AS21010 10G PHY (the 10G RJ45 WAN/combo) fixes from the same OpenWrt
          # tree: handle pipelined C45 reads, force a pipelined no-op aneg, and
          # fix a warm-reboot pipeline lag.
          {
            name = "as21xxx-pipelined-aneg";
            patch = ./patches/976-as21xxx-bind-force-pipelined-noop-aneg.patch;
          }
          {
            name = "as21xxx-warmreboot";
            patch = ./patches/979-as21xxx-warmreboot-fix.patch;
          }
          # mtk USXGMII PCS: do not reset the line side after link-up.
          {
            name = "pcs-mtk-usxgmii-no-reset";
            patch = ./patches/977-pcs-mtk-usxgmii-no-reset-after-linkup.patch;
          }
          # Netdev-watchdog recovery: a queue stalled WITHOUT an FE error must
          # recover that netdev alone (stop/start) instead of either doing
          # nothing (the old early return left the port dead until cold boot) or
          # resetting the whole FE and bouncing every MAC (WAN included).
          {
            name = "mtk-eth-tx-timeout-single-dev-recovery";
            patch = ./patches/981-mtk-eth-do-not-reset-all-macs-on-tx-timeout.patch;
          }
          # Warm-reset poll fix for MT7988: the FE clears RSTCTRL_FE
          # asynchronously, so polling for the asserted bit times out on every
          # recovery attempt and the cold-reset fallback leaves the MACs down
          # ("warm reset failed", total outage until reboot).  Poll for the
          # deasserted state instead (OpenWrt mtk_eth_soc form).
          {
            name = "mtk-eth-warm-reset-poll-fix";
            patch = ./patches/982-mtk-eth-warm-reset-fix.patch;
          }
        ];
        structuredExtraConfig =
          (prev.structuredExtraConfig or { })
          // (with lib.kernel; {
            # --- board networking drivers (the delta provides the code) ---
            NET_MEDIATEK_SOC = module;
            NET_MEDIATEK_SOC_WED = yes;
            NET_DSA = module;
            NET_DSA_MXL862 = module;
            NET_DSA_TAG_MXL_862XX = module;
            NET_DSA_TAG_MXL_862XX_8021Q = module;
            PCS_MTK_LYNXI = yes;
            PCS_MTK_USXGMII = yes;
            FWNODE_PCS = yes;
            PHY_COMMON_PROPS = yes;
            # 2.5G/10G PHYs used by the board
            MEDIATEK_2P5GE_PHY = module;
            MAXLINEAR_GPHY = module;
            # SFP cage support (sfp1 = LAN, sfp2 = WAN)
            SFP = module;
            # nixpkgs' common-config enables DAMON + all its sub-options.  DAMON's
            # reclaim/stat engines run kdamond continuously (~22% of a core here),
            # scanning and reclaiming memory and competing with kswapd.  Keep DAMON
            # itself on (its sub-options are only valid when it is, and disabling it
            # makes them "unused" and fails the config check), but turn off the
            # engines that actually burn CPU.
            DAMON_RECLAIM = lib.mkForce no;
            DAMON_LRU_SORT = lib.mkForce no;
            DAMON_STAT = lib.mkForce no;
          });
      })
    )
  );
}
