{ pkgs, ... }:

{
  programs.home-manager.enable = true;
  home.stateVersion = "21.05";

  home.username = builtins.getEnv "USER";
  home.homeDirectory = builtins.getEnv "HOME";


  home.packages = with pkgs; [
    diffr
    direnv
    fzf
    gh
    highlight
    htop
    jq
    shellcheck
    silver-searcher
    source-code-pro
    tree
    libffi

    vim_configurable
  ] ++ lib.optionals stdenv.isDarwin [
    gnused
  ];

  fonts.fontconfig.enable = true;

  programs.go.enable = true;
}
