{
  pkgs,
  nitroCli,
  tools,
  eif,
  eifName ? "enclave.eif",
  eifPath ? "/enclave/${eifName}",
  name ? "enclave-launcher",
  tag ? "latest",
  created ? "1970-01-01T00:00:01Z",
  user ? null,
  group ? null,
  extraContents ? [ ],
  extraCommands ? "",
  extraFakeRootCommands ? "",
  config ? { },
}:
let
  inherit (pkgs) lib;
  relativeEifPath = lib.removePrefix "/" eifPath;
  userSetup = lib.optionalString (user != null) ''
    mkdir -p etc home/enclave tmp
    echo "enclave:x:${user}:${group}:Enclave:/home/enclave:/bin/sh" > etc/passwd
    echo "enclave:x:${group}:" > etc/group
  '';
  ownership = lib.optionalString (user != null) ''
    chown -R ${user}:${group} home/enclave tmp ${lib.dirOf relativeEifPath}
  '';
in
pkgs.dockerTools.buildLayeredImage {
  inherit name tag created;
  contents = pkgs.buildEnv {
    name = "${name}-root";
    paths = [ nitroCli ] ++ tools ++ extraContents;
    pathsToLink = [
      "/bin"
      "/sbin"
    ];
  };
  config = {
    WorkingDir = "/";
    Cmd = [ "/bin/sh" ];
    Env = lib.optional (user != null) "HOME=/home/enclave" ++ [
      "PATH=/bin:/usr/bin:/sbin"
    ];
  }
  // lib.optionalAttrs (user != null) {
    User = "${user}:${group}";
  }
  // config;
  extraCommands = ''
    mkdir -p var/log/nitro_enclaves run/nitro_enclaves
    install -Dm644 ${eif} ${relativeEifPath}
    ${userSetup}
    if [ ! -e bin/sh ]; then
      ln -s bash bin/sh
    fi
  ''
  + extraCommands;
  fakeRootCommands = ''
    chown -R ${
      if user != null then "${user}:${group}" else "0:0"
    } var/log/nitro_enclaves run/nitro_enclaves
  ''
  + ownership
  + extraFakeRootCommands;
}
