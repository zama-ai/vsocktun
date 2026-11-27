{ pkgs, rustPlatform }:
rustPlatform.buildRustPackage {
  pname = "nitro-cli";
  version = "1.5.2";
  src = pkgs.fetchzip {
    url = "https://github.com/aws/aws-nitro-enclaves-cli/archive/1c496ed730d2dc41ec5bff6df89b4f3185e18840.tar.gz";
    hash = "sha256-r3VBa/hMoD7Wuq2Fc4NVbdrJkZYj4uziZk24Y1e/1GA=";
  };
  cargoHash = "sha256-W15GQQraJJ0ad8TbAq9fAWMvKHyDYXJ3UJmjjICDEIw=";
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];
  # nixpkgs' Cargo setup hook asks aws-lc-sys to link the system OpenSSL, but
  # newer OpenSSL releases do not provide the AWS-LC-compatible headers.
  preBuild = ''
    export AWS_LC_SYS_USE_SYSTEM=0
  '';
  cargoBuildFlags = [
    "--bin"
    "nitro-cli"
  ];
  cargoTestFlags = [
    "--package"
    "aws-nitro-enclaves-enclave-build"
    "yaml_generator::tests"
  ];
}
