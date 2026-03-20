{
  lib,
  pkgs,
}:
with lib;
let
  mkSecureCurl = import ../../lib/mk-secure-curl.nix { inherit lib pkgs; };
in
{
  type = mkOption {
    type = types.listOf (
      types.submodule {
        freeformType = types.attrsOf types.anything;
        options = {
          name = mkOption {
            type = types.str;
            description = "User-defined name for the indexer proxy";
          };
          implementationName = mkOption {
            type = types.enum [
              "FlareSolverr"
              "Http"
              "Socks4"
              "Socks5"
            ];
            description = "Type of indexer proxy to configure (matches schema implementationName)";
          };
          tags = mkOption {
            type = types.listOf types.str;
            default = [ ];
            description = "List of tag labels to assign to this indexer proxy. Tags must be defined in prowlarr.config.tags.";
          };
        };
      }
    );
    default = [ ];
    description = ''
      List of indexer proxies to configure in Prowlarr.
      Any additional attributes beyond name, implementationName, and tags
      will be applied as field values to the indexer proxy schema.
    '';
  };

  mkService = serviceConfig: {
    description = "Configure Prowlarr indexer proxies via API";
    after = [
      "prowlarr-config.service"
    ]
    ++ optional (serviceConfig.tags != [ ]) "prowlarr-tags.service";
    requires = [
      "prowlarr-config.service"
    ]
    ++ optional (serviceConfig.tags != [ ]) "prowlarr-tags.service";
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -eu

      BASE_URL="http://127.0.0.1:${builtins.toString serviceConfig.hostConfig.port}${serviceConfig.hostConfig.urlBase}/api/${serviceConfig.apiVersion}"

      # Read tag mapping
      TAG_MAPPING=$(cat /run/prowlarr/tags.json 2>/dev/null || echo '{}')

      # Fetch all indexer proxy schemas
      echo "Fetching indexer proxy schemas..."
      SCHEMAS=$(${
        mkSecureCurl serviceConfig.apiKey {
          url = "$BASE_URL/indexerProxy/schema";
          extraArgs = "-S";
        }
      })

      # Fetch existing indexer proxies
      echo "Fetching existing indexer proxies..."
      PROXIES=$(${
        mkSecureCurl serviceConfig.apiKey {
          url = "$BASE_URL/indexerProxy";
          extraArgs = "-S";
        }
      })

      # Build list of configured proxy names
      CONFIGURED_NAMES=$(cat <<'EOF'
      ${builtins.toJSON (map (p: p.name) serviceConfig.indexerProxies)}
      EOF
      )

      # Delete proxies not in configuration
      echo "Removing indexer proxies not in configuration..."
      echo "$PROXIES" | ${pkgs.jq}/bin/jq -r '.[] | @json' | while IFS= read -r proxy; do
        PROXY_NAME=$(echo "$proxy" | ${pkgs.jq}/bin/jq -r '.name')
        PROXY_ID=$(echo "$proxy" | ${pkgs.jq}/bin/jq -r '.id')

        if ! echo "$CONFIGURED_NAMES" | ${pkgs.jq}/bin/jq -e --arg name "$PROXY_NAME" 'index($name)' >/dev/null 2>&1; then
          echo "Deleting indexer proxy not in config: $PROXY_NAME (ID: $PROXY_ID)"
          ${
            mkSecureCurl serviceConfig.apiKey {
              url = "$BASE_URL/indexerProxy/$PROXY_ID";
              method = "DELETE";
              extraArgs = "-Sf";
            }
          } >/dev/null || echo "Warning: Failed to delete indexer proxy $PROXY_NAME"
        fi
      done

      ${concatMapStringsSep "\n" (
        proxyConfig:
        let
          proxyName = proxyConfig.name;
          inherit (proxyConfig) implementationName;
          allOverrides = builtins.removeAttrs proxyConfig [
            "implementationName"
            "tags"
          ];
          fieldOverrides = lib.filterAttrs (
            name: value: value != null && !lib.hasPrefix "_" name
          ) allOverrides;
          fieldOverridesJson = builtins.toJSON fieldOverrides;
          tagNamesJson = builtins.toJSON proxyConfig.tags;
        in
        ''
          echo "Processing indexer proxy: ${proxyName}"

          apply_field_overrides() {
            local proxy_json="$1"
            local overrides="$2"

            echo "$proxy_json" | ${pkgs.jq}/bin/jq \
              --argjson overrides "$overrides" '
                .name = $overrides.name
                | .fields[] |= (
                    . as $field |
                    if $overrides[$field.name] != null then
                      .value = $overrides[$field.name]
                    else
                      .
                    end
                  )
              '
          }

          FIELD_OVERRIDES=${escapeShellArg fieldOverridesJson}

          # Resolve tags
          RESOLVED_TAGS=$(echo "$TAG_MAPPING" | ${pkgs.jq}/bin/jq --argjson names '${tagNamesJson}' '[$names[] as $n | .[$n] // empty]')

          EXISTING_PROXY=$(echo "$PROXIES" | ${pkgs.jq}/bin/jq -r --arg name ${escapeShellArg proxyName} '.[] | select(.name == $name) | @json' || echo "")

          if [ -n "$EXISTING_PROXY" ]; then
            echo "Indexer proxy ${proxyName} already exists, updating..."
            PROXY_ID=$(echo "$EXISTING_PROXY" | ${pkgs.jq}/bin/jq -r '.id')

            UPDATED_PROXY=$(apply_field_overrides "$EXISTING_PROXY" "$FIELD_OVERRIDES")
            UPDATED_PROXY=$(echo "$UPDATED_PROXY" | ${pkgs.jq}/bin/jq --argjson tags "$RESOLVED_TAGS" '.tags = $tags')

            ${
              mkSecureCurl serviceConfig.apiKey {
                url = "$BASE_URL/indexerProxy/$PROXY_ID";
                method = "PUT";
                headers = {
                  "Content-Type" = "application/json";
                };
                data = "$UPDATED_PROXY";
                extraArgs = "-Sf";
              }
            } >/dev/null

            echo "Indexer proxy ${proxyName} updated"
          else
            echo "Indexer proxy ${proxyName} does not exist, creating..."

            SCHEMA=$(echo "$SCHEMAS" | ${pkgs.jq}/bin/jq -r --arg implName ${escapeShellArg implementationName} '.[] | select(.implementationName == $implName) | @json' || echo "")

            if [ -z "$SCHEMA" ]; then
              echo "Error: No schema found for indexer proxy implementationName ${implementationName}"
              exit 1
            fi

            NEW_PROXY=$(apply_field_overrides "$SCHEMA" "$FIELD_OVERRIDES")
            NEW_PROXY=$(echo "$NEW_PROXY" | ${pkgs.jq}/bin/jq --argjson tags "$RESOLVED_TAGS" '.tags = $tags')

            ${
              mkSecureCurl serviceConfig.apiKey {
                url = "$BASE_URL/indexerProxy";
                method = "POST";
                headers = {
                  "Content-Type" = "application/json";
                };
                data = "$NEW_PROXY";
                extraArgs = "-Sf";
              }
            } >/dev/null

            echo "Indexer proxy ${proxyName} created"
          fi
        ''
      ) serviceConfig.indexerProxies}

      echo "Prowlarr indexer proxies configuration complete"
    '';
  };
}
