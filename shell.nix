{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  buildInputs = [
    pkgs.python311
    pkgs.python311Packages.jupyter
    pkgs.nodejs
    pkgs.prettierd
  ];

  shellHook = ''
    export PATH=$PWD/node_modules/.bin:$PATH
  '';
}
