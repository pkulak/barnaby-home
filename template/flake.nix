{
  inputs.barnaby-home.url = "github:pkulak/barnaby-home";

  outputs =
    { barnaby-home, ... }:
    {
      nixosConfigurations.home = barnaby-home.inputs.nixpkgs.lib.nixosSystem {
        modules = [
          barnaby-home.nixosModules.default
          barnaby-home.nixosModules.vps
          ./configuration.nix
        ];
      };
    };
}
