{
  description = "Multi-queue TUN to VSOCK relay for AWS Nitro enclaves";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      rust-overlay,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      environments = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ rust-overlay.overlays.default ];
          };
          # Keep in step with the consumer's toolchain so that both builds share
          # one rustc derivation.
          toolchain = pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
          rustPlatform = pkgs.makeRustPlatform {
            cargo = toolchain;
            rustc = toolchain;
          };
          workspace = builtins.fromTOML (builtins.readFile ./Cargo.toml);
        in
        {
          inherit pkgs toolchain;
          vsocktun = rustPlatform.buildRustPackage {
            pname = "vsocktun";
            version = workspace.package.version;
            src = ./.;
            cargoLock.lockFile = ./Cargo.lock;
            # Upstream network tests require privileged network namespaces.
            doCheck = false;
            doInstallCheck = true;
            installCheckPhase = "$out/bin/vsocktun --help > /dev/null";
            strictDeps = true;
            meta = {
              description = workspace.package.description;
              mainProgram = "vsocktun";
              license = pkgs.lib.licenses.bsd3Clear;
            };
          };
        }
      );
    in
    {
      packages = forAllSystems (system: {
        inherit (environments.${system}) vsocktun;
        default = environments.${system}.vsocktun;
      });
      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
      });
      devShells = forAllSystems (
        system:
        let
          pkgs = environments.${system}.pkgs;
        in
        {
          default = pkgs.mkShell {
            packages = [
              (environments.${system}.toolchain.override {
                extensions = [
                  "rustfmt"
                  "clippy"
                  "rust-analyzer"
                ];
              })
              pkgs.stdenv.cc
              pkgs.iproute2
              pkgs.util-linux
              pkgs.strace
            ];
            shellHook = ''
              echo "vsocktun dev shell: $(rustc --version)"
              echo "The end-to-end tests are #[ignore]d; they need root, /dev/net/tun, VSOCK loopback, and iproute2."
            '';
          };
        }
      );
      formatter = forAllSystems (system: environments.${system}.pkgs.nixfmt);
    };
}
