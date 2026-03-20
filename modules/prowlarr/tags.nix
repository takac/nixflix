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
    type = types.listOf types.str;
    default = [ ];
    description = ''
      List of tag labels to manage in Prowlarr.
      Tags are used to link indexers with indexer proxies (e.g. FlareSolverr).
      Tags not in this list will be deleted from Prowlarr.
    '';
  };

  tagsFilePath = "/run/prowlarr/tags.json";

  mkService = serviceConfig: {
    description = "Configure Prowlarr tags via API";
    after = [ "prowlarr-config.service" ];
    requires = [ "prowlarr-config.service" ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };

    script = ''
      set -eu

      BASE_URL="http://127.0.0.1:${builtins.toString serviceConfig.hostConfig.port}${serviceConfig.hostConfig.urlBase}/api/${serviceConfig.apiVersion}"

      # Fetch existing tags
      echo "Fetching existing tags..."
      TAGS=$(${
        mkSecureCurl serviceConfig.apiKey {
          url = "$BASE_URL/tag";
          extraArgs = "-S";
        }
      })

      CONFIGURED_TAGS=$(cat <<'EOF'
      ${builtins.toJSON serviceConfig.tags}
      EOF
      )

      # Delete tags not in configuration
      echo "Removing tags not in configuration..."
      echo "$TAGS" | ${pkgs.jq}/bin/jq -r '.[] | @json' | while IFS= read -r tag; do
        TAG_LABEL=$(echo "$tag" | ${pkgs.jq}/bin/jq -r '.label')
        TAG_ID=$(echo "$tag" | ${pkgs.jq}/bin/jq -r '.id')

        if ! echo "$CONFIGURED_TAGS" | ${pkgs.jq}/bin/jq -e --arg label "$TAG_LABEL" 'index($label)' >/dev/null 2>&1; then
          echo "Deleting tag not in config: $TAG_LABEL (ID: $TAG_ID)"
          ${
            mkSecureCurl serviceConfig.apiKey {
              url = "$BASE_URL/tag/$TAG_ID";
              method = "DELETE";
              extraArgs = "-Sf";
            }
          } >/dev/null || echo "Warning: Failed to delete tag $TAG_LABEL"
        fi
      done

      # Create tags that don't exist yet
      ${concatMapStringsSep "\n" (tagLabel: ''
        echo "Processing tag: ${tagLabel}"

        EXISTS=$(echo "$TAGS" | ${pkgs.jq}/bin/jq --arg label ${escapeShellArg tagLabel} '[.[] | select(.label == $label)] | length')

        if [ "$EXISTS" = "0" ]; then
          echo "Creating tag: ${tagLabel}"
          TAG_JSON=$(${pkgs.jq}/bin/jq -n --arg label ${escapeShellArg tagLabel} '{label: $label}')
          ${
            mkSecureCurl serviceConfig.apiKey {
              url = "$BASE_URL/tag";
              method = "POST";
              headers = {
                "Content-Type" = "application/json";
              };
              data = "$TAG_JSON";
              extraArgs = "-Sf";
            }
          } >/dev/null
          echo "Tag ${tagLabel} created"
        else
          echo "Tag ${tagLabel} already exists"
        fi
      '') serviceConfig.tags}

      # Fetch final tags and write mapping file
      echo "Writing tag mapping..."
      FINAL_TAGS=$(${
        mkSecureCurl serviceConfig.apiKey {
          url = "$BASE_URL/tag";
          extraArgs = "-S";
        }
      })

      mkdir -p /run/prowlarr
      echo "$FINAL_TAGS" | ${pkgs.jq}/bin/jq '[.[] | {(.label): .id}] | add // {}' > /run/prowlarr/tags.json
      echo "Tag mapping written to /run/prowlarr/tags.json"

      echo "Prowlarr tags configuration complete"
    '';
  };
}
