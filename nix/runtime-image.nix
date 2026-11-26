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
