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
      crossTargets = {
        x86_64-linux = "aarch64-linux";
        aarch64-linux = "x86_64-linux";
      };
      importPkgs =
        system:
        import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
      makeRustPlatform =
        pkgs: toolchain:
        pkgs.makeRustPlatform {
          cargo = toolchain;
          rustc = toolchain;
        };
      makeEnvironment =
        pkgs:
        let
          inherit (pkgs.stdenv) buildPlatform hostPlatform;
          native = buildPlatform.canExecute hostPlatform;
          emulated = !native && hostPlatform.emulatorAvailable pkgs.buildPackages;
          # Keep in step with the consumer's toolchain so that both builds share
          # one rustc derivation.
          nativeToolchain = pkgs.buildPackages.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
          toolchain =
            if native then
              nativeToolchain
            else
              nativeToolchain.override { targets = [ hostPlatform.rust.rustcTarget ]; };
          rustPlatform = makeRustPlatform pkgs toolchain;
          workspace = builtins.fromTOML (builtins.readFile ./Cargo.toml);
          vsocktun = rustPlatform.buildRustPackage {
            pname = "vsocktun";
            version = workspace.package.version;
            src = ./.;
            cargoLock.lockFile = ./Cargo.lock;
            # Upstream network tests require privileged network namespaces.
            doCheck = false;
            doInstallCheck = native;
            installCheckPhase = "$out/bin/vsocktun --help > /dev/null";
            postFixup = pkgs.lib.optionalString emulated ''
              ${hostPlatform.emulator pkgs.buildPackages} "$out/bin/vsocktun" --help > /dev/null
            '';
            strictDeps = true;
            meta = {
              description = workspace.package.description;
              mainProgram = "vsocktun";
              license = pkgs.lib.licenses.bsd3Clear;
            };
          };
          enclaveParts = import ./nix/enclave.nix { inherit pkgs rustPlatform; };
          parentTools = import ./nix/parent-tools.nix { inherit pkgs vsocktun; };
          # eif_build runs on the builder; the kernel and image contents target Linux.
          eifBuild = import ./nix/eif-build.nix {
            pkgs = pkgs.buildPackages;
            rustPlatform = makeRustPlatform pkgs.buildPackages nativeToolchain;
          };
          eif = import ./nix/eif.nix {
            inherit pkgs eifBuild;
            inherit (enclaveParts)
              kernel
              bootstrap
              kernelCmdline
              ;
          };
        in
        {
          inherit
            pkgs
            toolchain
            vsocktun
            enclaveParts
            parentTools
            eif
            eifBuild
            ;
        };
      environments = forAllSystems (system: makeEnvironment (importPkgs system));
      crossEnvironments = forAllSystems (
        system:
        let
          inherit (environments.${system}.pkgs) pkgsCross;
        in
        makeEnvironment (
          if crossTargets.${system} == "aarch64-linux" then
            pkgsCross.aarch64-multiplatform
          else
            pkgsCross.gnu64
        )
      );
      darwinPkgs = importPkgs "aarch64-darwin";
      enclaveBuilders =
        env:
        let
          inherit (env) pkgs;
        in
        {
          inherit (env.enclaveParts)
            nitroCli
            kernel
            bootstrap
            ;
          inherit (env) eifBuild;
          mkEifDerivation = env.eif.mkDerivation;
          mkRuntimeImage =
            args:
            import ./nix/runtime-image.nix (
              {
                inherit pkgs;
                inherit (env) vsocktun;
              }
              // args
            );
          mkLauncherImage =
            args:
            import ./nix/launcher-image.nix (
              {
                inherit pkgs;
                inherit (env.enclaveParts) nitroCli;
                tools = env.parentTools.packages;
              }
              // args
            );
          parentTools = env.parentTools.env;
          parentToolsPackages = env.parentTools.packages;
        };
      checkEnclaveImages =
        env:
        import ./nix/check-enclave-images.nix {
          inherit (env) pkgs;
          enclave = enclaveBuilders env;
        };
    in
    {
      lib = forAllSystems (system: {
        enclave = enclaveBuilders environments.${system};
        cross.${crossTargets.${system}}.enclave = enclaveBuilders crossEnvironments.${system};
      });
      packages =
        forAllSystems (
          system:
          let
            env = environments.${system};
            crossEnv = crossEnvironments.${system};
          in
          {
            inherit (env) vsocktun;
            nitro-cli = env.enclaveParts.nitroCli;
            enclave-kernel = env.enclaveParts.kernel;
            enclave-bootstrap = env.enclaveParts.bootstrap;
            enclave-eif-build = env.eifBuild;
            enclave-parent-tools = env.parentTools.env;
            default = env.vsocktun;
          }
          // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
            vsocktun-aarch64 = crossEnv.vsocktun;
            nitro-cli-aarch64 = crossEnv.enclaveParts.nitroCli;
            enclave-kernel-aarch64 = crossEnv.enclaveParts.kernel;
            enclave-bootstrap-aarch64 = crossEnv.enclaveParts.bootstrap;
            enclave-parent-tools-aarch64 = crossEnv.parentTools.env;
          }
          // nixpkgs.lib.optionalAttrs (system == "aarch64-linux") {
            vsocktun-x86_64 = crossEnv.vsocktun;
          }
        )
        // {
          aarch64-darwin = {
            vsocktun-x86_64 = (makeEnvironment darwinPkgs.pkgsCross.gnu64).vsocktun;
            vsocktun-aarch64-static =
              (makeEnvironment darwinPkgs.pkgsCross.aarch64-multiplatform.pkgsStatic).vsocktun;
          };
        };
      checks =
        forAllSystems (system: {
          default = self.packages.${system}.default;
          enclave-eif-build = self.packages.${system}.enclave-eif-build;
          enclave-images = checkEnclaveImages environments.${system};
          enclave-images-cross = checkEnclaveImages crossEnvironments.${system};
        })
        // {
          aarch64-darwin = {
            inherit (self.packages.aarch64-darwin) vsocktun-x86_64 vsocktun-aarch64-static;
          };
        };
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
