{
  barnabyHome = {
    domain = "barn.example.com";

    # The machine's disk (`lsblk -dp` lists them). The install erases it.
    disk = "/dev/sda";

    # Usernames that become server admins when they sign up.
    admins = [ "dave" ];

    # The weather skill's default location, as "latitude,longitude".
    # location = "41.88,-87.63";

    agent = {
      name = "Barnaby";

      # The agent's personality and what it knows about everyone. Without
      # this, it uses Barnaby's generic one with the name above.
      # soul = ./soul.md;

      # Bundled skills beyond the defaults. Each needs keys in secrets.env.
      # skills.weather = true;
      # skills.web-search = true;
      # skills.calendar = true;
    };
  };

  time.timeZone = "America/Chicago";

  users.users.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAA... you@laptop"
  ];

  # Written by nixos-anywhere during the install.
  hardware.facter.reportPath = ./facter.json;

  networking.hostName = "barnaby-home";
  system.stateVersion = "26.11";
}
