with import <nixpkgs> {};

pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    curl
  ];

  hardeningDisable = [ "all" ];
}
