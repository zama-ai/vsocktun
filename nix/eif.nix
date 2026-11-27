{
  pkgs,
  eifBuild,
  kernel,
  bootstrap,
  kernelCmdline,
}:
let
  inherit (pkgs) lib;
  kernelName = if pkgs.stdenv.hostPlatform.isx86_64 then "bzImage" else "Image";
  arch = if pkgs.stdenv.hostPlatform.isx86_64 then "x86_64" else "aarch64";
  # Fixed so the EIF metadata is reproducible. It is not part of PCR0-PCR2.
  buildTime = "1970-01-01T00:00:01Z";

  # Convert the Nix image tarball to an OCI layout, unpack it with umoci, and
  # write the two initrds expected by the Nitro bootstrap init. Everything is
  # file-based, so this runs in the sandbox and is cached by Nix.
  initrds =
    image:
    pkgs.runCommand "enclave-initrds"
      {
        nativeBuildInputs = [
          pkgs.skopeo
          pkgs.umoci
          pkgs.cpio
          pkgs.jq
          pkgs.findutils
          pkgs.coreutils
        ];
      }
      ''
        export HOME="$TMPDIR/home"
        export XDG_RUNTIME_DIR="$TMPDIR/run"
        mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$out"
        work=$(mktemp -d)
        trap 'chmod -R u+w -- "$work" 2>/dev/null || true; rm -rf -- "$work"' EXIT

        mkdir -p "$work/oci" "$work/bootstrap/dev" "$work/customer"
        image=${lib.escapeShellArg (toString image)}

        skopeo --insecure-policy --tmpdir "$TMPDIR" copy \
          "docker-archive:$image" "oci:$work/oci:latest"
        skopeo --insecure-policy --tmpdir "$TMPDIR" inspect --config \
          "docker-archive:$image" > "$work/config.json"
        jq -r '(.config.Cmd // .config.Entrypoint)[]' "$work/config.json" > "$work/cmd"
        jq -r '.config.Env[]?' "$work/config.json" > "$work/env"

        umoci unpack --rootless --image "$work/oci:latest" "$work/bundle"
        rootfs="$work/bundle/rootfs"
        for directory in dev run sys var proc tmp; do
          mkdir -p "$rootfs/$directory"
        done

        install -Dm0755 ${lib.escapeShellArg "${bootstrap}/bin/init"} "$work/bootstrap/init"
        find "$work/bootstrap" -exec touch -h -d @1 {} +
        (
          cd "$work/bootstrap"
          find . -mindepth 1 -printf '%P\0' |
            sort -z |
            cpio --null -o --format=newc --owner=0:0 --reproducible
        ) > "$out/bootstrap.cpio"

        mv "$rootfs" "$work/customer/rootfs"
        install -Dm0644 "$work/cmd" "$work/customer/cmd"
        install -Dm0644 "$work/env" "$work/customer/env"
        find "$work/customer" -exec touch -h -d @1 {} +
        (
          cd "$work/customer"
          find . -mindepth 1 -printf '%P\0' |
            sort -z |
            cpio --null -o --format=newc --owner=0:0 --reproducible
        ) > "$out/customer.cpio"
      '';

  # Assemble the EIF with AWS's eif_build. The AWS tool owns EIF metadata,
  # measurements, and signing; Nix owns the inputs and the output paths.
  mkDerivation =
    {
      image,
      name ? "enclave",
      version ? "1",
    }:
    let
      initrd = initrds image;
    in
    pkgs.runCommand "enclave-eif-${name}"
      {
        nativeBuildInputs = [
          eifBuild
          pkgs.coreutils
          pkgs.gnused
        ];
      }
      ''
        mkdir -p "$out"
        eif_build \
          --kernel ${lib.escapeShellArg "${kernel}/${kernelName}"} \
          --cmdline "$(cat ${lib.escapeShellArg (toString kernelCmdline)})" \
          --ramdisk ${initrd}/bootstrap.cpio \
          --ramdisk ${initrd}/customer.cpio \
          --output "$out/enclave.eif" \
          --name ${lib.escapeShellArg (toString name)} \
          --version ${lib.escapeShellArg (toString version)} \
          --arch ${lib.escapeShellArg arch} \
          --build-time ${lib.escapeShellArg buildTime} \
          --img-os Linux \
          --img-kernel ${lib.escapeShellArg (kernel.modDirVersion or kernel.version)} \
          > "$out/eif-build.txt"
        sed -n '/^{/,$p' "$out/eif-build.txt" > "$out/pcr.json"
        (cd "$out"; sha256sum enclave.eif > sha256.txt)
      '';
in
{
  inherit mkDerivation;
}
