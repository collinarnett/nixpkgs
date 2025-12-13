{
  config,
  lib,
  pkgs,
  options,
  ...
}:

let
  cfg = config.services.prometheus.exporters.dcgm;
  inherit (lib) mkOption types concatStringsSep;
in
{
  port = 9400;
  extraOpts = {
    path = mkOption {
      type = types.path;
      defaultText = "default-counters.csv";
      default = "${pkgs.prometheus-dcgm-exporter}/share/etc/dcgm-exporter/default-counters.csv";
      description = ''
        Path to file containing DCGM fields to collect.
      '';
    };

    collectInterval = mkOption {
      type = types.int;
      default = 30000;
      description = ''
        Interval of time at which point metrics are collected.
      '';
    };

    devices = mkOption {
      type = types.str;
      default = "f";
      description = ''
        Specify which devices to monitor. Default: all GPU instances in MIG mode, all GPUs if MIG disabled.
      '';
    };

  };
  serviceOpts = {
    serviceConfig = {
      ExecStart = ''
        ${pkgs.prometheus-dcgm-exporter}/bin/dcgm-exporter \
          --disable-startup-validate \
          -a ${cfg.listenAddress}:${toString cfg.port} \
          -f ${cfg.path} \
          -c ${toString cfg.collectInterval} \
          ${concatStringsSep " \\\n  " cfg.extraFlags}
      '';
      PrivateDevices = false;
    };
    wantedBy = [ "multi-user.target" ];
  };
}
