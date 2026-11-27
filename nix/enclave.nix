{ pkgs, rustPlatform }:
let
  inherit (pkgs) lib;
  arch = pkgs.stdenv.hostPlatform.uname.processor;
  bootstrapSource = pkgs.fetchFromGitHub {
    owner = "aws";
    repo = "aws-nitro-enclaves-sdk-bootstrap";
    rev = "f718dea60a9d9bb8b8682fd852ad793912f3c5db";
    hash = "sha256-DmNnH6lqweRz1u8nza6FvgJFvDGPactpHruyq0SYkp8=";
  };
  nitroCli = import ./nitro-cli.nix { inherit pkgs rustPlatform; };
  bootstrap = pkgs.pkgsStatic.stdenv.mkDerivation {
    pname = "nitro-bootstrap-init";
    version = "f718dea";
    src = bootstrapSource + "/init";
    buildPhase = "$CC -Wall -Wextra -Werror -O2 -o init init.c";
    installPhase = ''install -Dm755 init "$out/bin/init"'';
  };
  kernelBase = pkgs.linuxKernel.kernels.linux_6_12;
  kernelConfig =
    (kernelBase.override {
      # alldefconfig accepts a full baseline through KCONFIG_ALLCONFIG and fills
      # newly introduced options with their defaults before applying overrides.
      defconfig = "alldefconfig";
      extraMakeFlags = [ "KCONFIG_ALLCONFIG=${bootstrapSource}/kernel/microvm-kernel-config-${arch}" ];
      enableCommonConfig = false;
      autoModules = false;
      preferBuiltin = true;
      ignoreConfigErrors = false;
      structuredExtraConfig = with lib.kernel; {
        NSM = yes;
        TUN = yes;
        MODULES = no;
        # Rust may be hidden when the Rust toolchain is unavailable.
        RUST = option no;
        VIRTIO_MMIO = yes;
        VIRTIO_MMIO_CMDLINE_DEVICES = yes;
        VSOCKETS = yes;
        VIRTIO_VSOCKETS = yes;
        LOCALVERSION_AUTO = no;
        LOCALVERSION = freeform "";
        SYSTEM_TRUSTED_KEYS = freeform "";
        SYSTEM_REVOCATION_LIST = no;
        DEBUG_INFO_NONE = yes;
      };
    }).configfile;
  kernel =
    (pkgs.linuxKernel.manualConfig {
      pname = "kms-enclave-linux";
      inherit (kernelBase) version src;
      configfile = kernelConfig;
      extraMakeFlags = [
        "KBUILD_BUILD_USER=nixbuild"
        "KBUILD_BUILD_HOST=nixbuilder"
      ];
      # These build capabilities must agree with the resolved config, without IFD.
      config = {
        CONFIG_MODULES = "n";
        CONFIG_RUST = "n";
      };
      buildDTBs = false;
    }).overrideAttrs
      (
        previous:
        lib.optionalAttrs (arch == "aarch64") {
          postInstall = (previous.postInstall or "") + ''
            # Nitro's ARM loader needs an explicit text offset, as in AWS's bootstrap build.
            chmod u+w "$out/Image"
            printf '\x00\x00\x20\x00\x00\x00\x00\x00' | dd of="$out/Image" bs=1 count=8 seek=8 conv=notrunc
          '';
        }
      );
  kernelCmdline = bootstrapSource + "/kernel/cmdline/${arch}.cmdline";
in
{
  inherit
    nitroCli
    bootstrap
    kernel
    kernelCmdline
    ;
}
