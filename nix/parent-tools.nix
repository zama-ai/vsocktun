{ pkgs, vsocktun }:
let
  packages = [
    vsocktun
    pkgs.bash
    pkgs.coreutils
    pkgs.socat
    pkgs.yq-go
    pkgs.net-tools
    pkgs.iproute2
    pkgs.iptables
    pkgs.procps
    pkgs.dnsproxy
  ];
in
{
  inherit packages;
  env = pkgs.buildEnv {
    name = "enclave-parent-tools";
    paths = packages;
    pathsToLink = [
      "/bin"
      "/sbin"
    ];
  };
}
