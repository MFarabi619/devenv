{ pkgs, lib, config, ... }:

{
  packages = [
    # A python dependency outside of poetry.
    config.languages.python.package.pkgs.pjsua2
    pkgs.zlib
    # Build tools needed for compiling Python packages
    pkgs.ninja
  ];

  languages.python = {
    enable = true;
    poetry = {
      enable = true;
      install = {
        enable = true;
        installRootPackage = false;
        onlyInstallRootPackage = false;
        compile = false;
        quiet = false;
        groups = [ ];
        ignoredGroups = [ ];
        onlyGroups = [ ];
        extras = [ ];
        allExtras = false;
        verbosity = "no";
      };
      activate.enable = true;
      package = pkgs.poetry;
    };
  };
}
