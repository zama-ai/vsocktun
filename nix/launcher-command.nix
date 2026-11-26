{
  pkgs,
  flakePath,
  system ? pkgs.stdenv.hostPlatform.system,
  inputName ? "vsocktun",
  name ? "enclave-launcher",
  tag ? "latest",
  eifName ? "enclave.eif",
  eifPath ? "/enclave/${eifName}",
  user ? null,
  group ? null,
  extraContents ? [ ],
  config ? { },
  created ? "1970-01-01T00:00:01Z",
}:
let
  launcherArgs = pkgs.writeText "enclave-launcher-args.json" (
    builtins.toJSON {
      inherit
        name
        tag
        eifName
        eifPath
        user
        group
        config
        created
        ;
      extraContents = map toString extraContents;
    }
  );
  expression = pkgs.writeText "build-enclave-launcher.nix" ''
    let
      f = builtins.getFlake "path:${toString flakePath}";
      enclave = f.inputs.${inputName}.lib.${system}.enclave;
      args = builtins.fromJSON (builtins.readFile ${launcherArgs});
      eif = builtins.path {
        path = builtins.getEnv "EIF_PATH";
        name = "enclave.eif";
      };
    in
    enclave.mkLauncherImage (args // { eif = eif; })
  '';
in
pkgs.writeShellApplication {
  name = "build-enclave-launcher";
  runtimeInputs = [
    pkgs.nix
    pkgs.coreutils
  ];
  text = ''
    if [ "$#" -ne 2 ]; then
      echo "Usage: build-enclave-launcher EIF_DIRECTORY OUTPUT_DIRECTORY" >&2
      exit 2
    fi
    eif=$(realpath -- "$1")
    output=$(realpath -m -- "$2")
    if [ -e "$output" ]; then
      echo "Output directory already exists: $output" >&2
      exit 1
    fi
    if [ -d "$eif" ]; then
      eif="$eif/enclave.eif"
    fi
    mkdir -p -- "$output"
    store=$(EIF_PATH="$eif" nix build --impure --no-link --print-out-paths -f ${expression})
    cp -L "$store" "$output/image.tar.gz"
    (cd "$output"; sha256sum image.tar.gz > sha256.txt)
  '';
}
