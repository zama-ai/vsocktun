{
  pkgs,
  nitroCli,
  linuxkit,
  kernel,
  init,
  kernelCmdline,
}:
let
  inherit (pkgs) lib;
  kernelName = if pkgs.stdenv.hostPlatform.isx86_64 then "bzImage" else "Image";
  blobs = pkgs.linkFarm "nitro-enclave-blobs" [
    {
      name = kernelName;
      path = "${kernel}/${kernelName}";
    }
    {
      name = "${kernelName}.config";
      path = kernel.configfile;
    }
    {
      name = "init";
      path = "${init}/bin/init";
    }
    {
      name = "cmdline";
      path = kernelCmdline;
    }
    {
      name = "linuxkit";
      path = "${linuxkit}/bin/linuxkit";
    }
  ];
  dockerHost = ''
    if [ -z "''${DOCKER_HOST:-}" ]; then
      for socket in /run/user/*/docker.sock /run/docker.sock /var/run/docker.sock; do
        if [ -S "$socket" ]; then
          export DOCKER_HOST="unix://$socket"
          if docker info > /dev/null 2>&1; then
            break
          fi
          unset DOCKER_HOST
        fi
      done
    fi
    if [ -z "''${DOCKER_HOST:-}" ] && docker context inspect >/dev/null 2>&1; then
      DOCKER_HOST=$(docker context inspect --format '{{.Endpoints.docker.Host}}')
      export DOCKER_HOST
    fi
    if [ -z "''${DOCKER_HOST:-}" ]; then
      echo "could not find a working Docker daemon; set DOCKER_HOST" >&2
      exit 1
    fi
    unset DOCKER_CONTEXT
    docker info > /dev/null
  '';
  commonEnv = ''
    export HOME="$work/home"
    export NITRO_CLI_LOGS_PATH="$work/logs"
    export NITRO_CLI_ARTIFACTS="$work/artifacts"
    export NITRO_CLI_BLOBS=${blobs}
    mkdir -p "$HOME" "$NITRO_CLI_LOGS_PATH" "$NITRO_CLI_ARTIFACTS"
  '';
in
{
  # Build an EIF and leave it in a directory chosen by the caller. Assembly
  # needs the host Docker daemon, so this runs through `nix run`.
  mkCommand =
    {
      image,
      name ? "enclave",
      version ? "1",
    }:
    pkgs.writeShellApplication {
      name = "build-enclave-eif";
      runtimeInputs = [
        nitroCli
        pkgs.docker-client
        pkgs.coreutils
        pkgs.jq
      ];
      text = ''
        if [ "$#" -ne 1 ]; then
          echo "Usage: build-enclave-eif OUTPUT_DIRECTORY" >&2
          exit 2
        fi
        output=$(realpath -m -- "$1")
        if [ -e "$output" ]; then
          echo "Output directory already exists: $output" >&2
          exit 1
        fi
        ${dockerHost}
        work=$(mktemp -d)
        cleanup() {
          status=$?
          if [ "$status" -eq 0 ]; then
            rm -rf -- "$work"
          else
            echo "Build artifacts retained in $work" >&2
          fi
        }
        trap cleanup EXIT
        ${commonEnv}
        mkdir -p -- "$output"
        docker load --input ${image}
        nitro-cli build-enclave --docker-uri ${image.imageName}:${image.imageTag} \
          --name ${name} --version ${version} --output-file "$output/enclave.eif" > "$work/build-info.json"
        jq -e '.Measurements' "$work/build-info.json" > "$output/pcr.json"
        nitro-cli describe-eif --eif-path "$output/enclave.eif" > "$work/described-eif.json"
        jq -e '.CheckCRC == true and .IsSigned == false' "$work/described-eif.json"
        jq '.Measurements' "$work/described-eif.json" | cmp - "$output/pcr.json"
        (cd "$output"; sha256sum enclave.eif > sha256.txt)
      '';
    };

  # Build an EIF as a store path so an image can embed it. This uses the host
  # Docker daemon, so the derivation runs without a sandbox and cannot be
  # substituted from a binary cache.
  mkDerivation =
    {
      image,
      name ? "enclave",
      version ? "1",
    }:
    pkgs.runCommand "enclave-eif-${name}"
      {
        __noSandbox = true;
        impureEnvVars = [ "DOCKER_HOST" ];
        nativeBuildInputs = [
          nitroCli
          pkgs.docker-client
          pkgs.coreutils
          pkgs.jq
        ];
      }
      ''
        work=$(mktemp -d)
        trap 'rm -rf -- "$work"' EXIT
        ${commonEnv}
        ${dockerHost}
        mkdir -p "$out"
        docker load --input ${image}
        nitro-cli build-enclave --docker-uri ${image.imageName}:${image.imageTag} \
          --name ${name} --version ${version} --output-file "$out/enclave.eif" > "$work/build-info.json"
        jq -e '.Measurements' "$work/build-info.json" > "$out/pcr.json"
        nitro-cli describe-eif --eif-path "$out/enclave.eif" > "$work/described-eif.json"
        jq -e '.CheckCRC == true and .IsSigned == false' "$work/described-eif.json"
        jq '.Measurements' "$work/described-eif.json" | cmp - "$out/pcr.json"
        (cd "$out"; sha256sum enclave.eif > sha256.txt)
      '';

  inherit blobs;
}
