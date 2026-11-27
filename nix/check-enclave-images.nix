{ pkgs, enclave }:
let
  inherit (pkgs) buildPackages;
  platform = pkgs.stdenv.hostPlatform;
  architecture = platform.go.GOARCH;
  machine = if platform.isAarch64 then "AArch64" else "Advanced Micro Devices X86-64";
  binutils = buildPackages.binutils-unwrapped;
  readelf = "${pkgs.lib.getBin binutils}/bin/${binutils.targetPrefix}readelf";
  baseImage = pkgs.dockerTools.buildLayeredImage {
    name = "enclave-check-base";
    contents = pkgs.buildEnv {
      name = "enclave-check-root";
      paths = [ pkgs.bash ];
      pathsToLink = [ "/bin" ];
    };
  };
  image = enclave.mkRuntimeImage {
    inherit baseImage;
    name = "enclave-check-runtime";
    tag = "latest";
    entrypoint = pkgs.writeText "enclave-check-init.sh" "exit 0";
  };
  eif = enclave.mkEifDerivation { inherit image; };
  launcher = enclave.mkLauncherImage { eif = "${eif}/enclave.eif"; };
in
buildPackages.runCommand "check-enclave-images-${platform.system}"
  {
    nativeBuildInputs = with buildPackages; [
      jq
      skopeo
      umoci
    ];
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    unpack() {
      local archive="docker-archive:$1"
      skopeo --insecure-policy --tmpdir "$TMPDIR" --override-arch ${architecture} inspect --config "$archive" |
        jq -e '.os == "linux" and .architecture == "${architecture}"'
      skopeo --insecure-policy --tmpdir "$TMPDIR" --override-arch ${architecture} copy "$archive" "oci:$2-oci:latest"
      umoci unpack --rootless --image "$2-oci:latest" "$2"
    }
    check_elf() {
      LC_ALL=C ${readelf} -h "$1" |
        grep -E 'Machine: +${machine}$'
    }

    unpack ${image} runtime
    check_elf "runtime/rootfs${pkgs.bash}/bin/bash"
    check_elf "$(find runtime/rootfs/nix/store -type f -path '*/bin/vsocktun' -print -quit)"
    unpack ${launcher} launcher
    check_elf "$(find launcher/rootfs/nix/store -type f -path '*/bin/nitro-cli' -print -quit)"
    test -s ${eif}/enclave.eif
    (cd ${eif}; sha256sum -c sha256.txt)
    cmp ${eif}/enclave.eif launcher/rootfs/enclave/enclave.eif
    touch "$out"
  ''
