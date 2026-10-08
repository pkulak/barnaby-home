# A single-disk VPS installed with nixos-anywhere. Hardware detection comes
# from nixos-facter (`hardware.facter.reportPath`), so nothing here is
# specific to a provider.
{ disko }:
{ config, lib, ... }:
{
  imports = [ disko.nixosModules.disko ];

  options.barnabyHome.disk = lib.mkOption {
    type = lib.types.str;
    example = "/dev/sda";
    description = "The disk to install onto. Everything on it is erased.";
  };

  config = {
    disko.devices.disk.main = {
      type = "disk";
      device = config.barnabyHome.disk;
      content = {
        type = "gpt";
        partitions = {
          boot = {
            size = "1M";
            type = "EF02";
          };
          esp = {
            size = "512M";
            type = "EF00";
            content = {
              type = "filesystem";
              format = "vfat";
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          root = {
            size = "100%";
            content = {
              type = "filesystem";
              format = "ext4";
              mountpoint = "/";
            };
          };
        };
      };
    };

    # GRUB with both a BIOS boot partition and a removable EFI install, so it
    # boots whichever way the provider starts the machine.
    boot.loader.grub = {
      enable = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
    };

    # Most providers show the serial console in their web UI.
    boot.kernelParams = [
      "console=tty0"
      "console=ttyS0,115200n8"
    ];

    zramSwap.enable = true;
    services.openssh.enable = true;

    nix.settings.experimental-features = [
      "nix-command"
      "flakes"
    ];
  };
}
