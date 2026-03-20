{
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.nixflix.flaresolverr;
  hostname = "${cfg.subdomain}.${config.nixflix.nginx.domain}";
in
{
  options.nixflix.flaresolverr = {
    enable = mkEnableOption "FlareSolverr";

    port = mkOption {
      type = types.port;
      default = 8191;
      description = "Port for FlareSolverr to listen on.";
    };

    subdomain = mkOption {
      type = types.str;
      default = "flaresolverr";
      description = "Subdomain prefix for nginx reverse proxy.";
    };
  };

  config = mkIf (config.nixflix.enable && cfg.enable) {
    services.flaresolverr = {
      enable = true;
      inherit (cfg) port;
    };

    services.nginx.virtualHosts."${hostname}" = mkIf config.nixflix.nginx.enable {
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString cfg.port}";
        recommendedProxySettings = true;
        extraConfig = ''
          proxy_redirect off;
        '';
      };
    };

    networking.hosts = mkIf (config.nixflix.nginx.enable && config.nixflix.nginx.addHostsEntries) {
      "127.0.0.1" = [ hostname ];
    };
  };
}
