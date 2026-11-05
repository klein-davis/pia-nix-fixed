{ pkgs, resources }:
pkgs.writeShellApplication {
  name = "pia-switch";

  runtimeInputs = with pkgs; [
    coreutils
    findutils
    fzf
    gawk
    gnugrep
    gnused
    networkmanager
  ];

  text = ''
    PIA_CONFIG_DIR=${resources}
  '' + builtins.readFile ./pia-switch.sh;
}
