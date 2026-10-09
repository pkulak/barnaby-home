# The tool behind the barnaby-home launcher. It runs in the launcher's
# nixos/nix container, so it uses that Nix.
{
  writeShellApplication,
  python3,
  git,
  openssh,
  nixos-anywhere,
  nixos-rebuild-ng,
  tzdata,
}:
let
  python = python3.withPackages (ps: [ ps.questionary ]);
in
writeShellApplication {
  name = "barnaby-home";
  runtimeInputs = [
    git
    openssh
    nixos-anywhere
    nixos-rebuild-ng
  ];
  runtimeEnv = {
    BARNABY_HOME_TEMPLATE = "${../template}";
    BARNABY_HOME_ZONEINFO = "${tzdata}/share/zoneinfo";
  };
  text = ''exec ${python.interpreter} ${./barnaby_home.py} "$@"'';
}
