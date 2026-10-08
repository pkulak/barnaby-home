{
  description = "Barnaby Home: a family Matrix server with a Barnaby agent, in one NixOS flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    barnaby.url = "github:pkulak/barnaby";
    barnaby.inputs.nixpkgs.follows = "nixpkgs";

    llm-agents.url = "github:numtide/llm-agents.nix";
    llm-agents.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      self,
      nixpkgs,
      disko,
      barnaby,
      llm-agents,
    }:
    let
      inherit (nixpkgs.lib.modules) importApply;
    in
    {
      # The services: Matrix, Element, calls, and the agent.
      nixosModules.default = importApply ./modules/barnaby-home.nix { inherit barnaby llm-agents; };

      # The machine: disk layout, boot loader, and SSH.
      nixosModules.vps = importApply ./modules/vps.nix { inherit disko; };

      templates.default = {
        path = ./template;
        description = "A family's Barnaby Home server";
      };

      checks.x86_64-linux.vm = import ./tests/vm.nix {
        pkgs = nixpkgs.legacyPackages.x86_64-linux;
        module = self.nixosModules.default;
      };
    };
}
