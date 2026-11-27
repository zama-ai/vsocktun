{
  pkgs,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "eif-build";
  version = "0.3.2";
  src = pkgs.fetchFromGitHub {
    owner = "aws";
    repo = "aws-nitro-enclaves-image-format";
    rev = "v0.8.1";
    hash = "sha256-6Rb/5Q/75jYO2Cag9S/kNbnOEj6HVmVDjp/WPP5iYx4=";
  };
  # The upstream tag has no Cargo.lock. Keep one here so the dependency set
  # does not drift. This is AWS's lock, not the old handrolled builder's.
  cargoLock.lockFile = ./aws-eif-build.lock;
  postPatch = ''
    cp ${./aws-eif-build.lock} Cargo.lock
  '';
  patches = [ ./eif-build-version.patch ];
  cargoBuildFlags = [
    "--package"
    "eif_build"
  ];
  cargoInstallFlags = [
    "--package"
    "eif_build"
  ];
  cargoTestFlags = [
    "--package"
    "eif_build"
  ];
  nativeBuildInputs = [ pkgs.pkg-config ];
  buildInputs = [ pkgs.openssl ];
  # As in nitro-cli, keep aws-lc-sys away from the system OpenSSL headers.
  preBuild = ''
    export AWS_LC_SYS_USE_SYSTEM=0
  '';
  meta = {
    description = "AWS EIF assembly CLI from aws-nitro-enclaves-image-format.";
    mainProgram = "eif_build";
    license = pkgs.lib.licenses.asl20;
  };
}
