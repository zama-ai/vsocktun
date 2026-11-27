{
  pkgs,
  vsocktun,
  baseImage,
  entrypoint,
  name,
  tag,
  created ? baseImage.created or "1970-01-01T00:00:01Z",
  extraContents ? [ ],
  config ? { },
}:
let
  inherit (pkgs) buildPackages lib;
  architecture = pkgs.stdenv.hostPlatform.go.GOARCH;
  entrypointWrapper = pkgs.writeShellScriptBin "enclave-entrypoint" ''
    exec /bin/bash ${entrypoint}
  '';
in
pkgs.dockerTools.buildLayeredImage {
  inherit name tag created;
  fromImage = baseImage;
  config =
    (baseImage.config or { })
    // {
      User = "0:0";
      WorkingDir = "/";
      Cmd = [ "/bin/enclave-entrypoint" ];
    }
    // config;
  extraCommands = ''
    export HOME="$TMPDIR"
    if ! ${lib.getExe buildPackages.skopeo} --insecure-policy --tmpdir "$TMPDIR" --override-os linux \
      --override-arch ${architecture} inspect --config \
      ${lib.escapeShellArg "docker-archive:${baseImage}"} |
      ${lib.getExe buildPackages.jq} -e \
        '.os == "linux" and .architecture == "${architecture}"' >/dev/null; then
      echo "Expected a linux/${architecture} base image" >&2
      exit 1
    fi
  '';
  contents = pkgs.buildEnv {
    name = "${name}-enclave-root";
    paths = [
      entrypointWrapper
      vsocktun
      pkgs.socat
      pkgs.net-tools
      pkgs.yq-go
    ]
    ++ extraContents;
    pathsToLink = [ "/bin" ];
  };
}
