{ barnaby, llm-agents }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.barnabyHome;
  agent = cfg.agent;
  domain = cfg.domain;

  # Generated on first boot. Everything here is root-only and reaches the
  # services through systemd credentials or the Barnaby container's env files.
  stateDir = "/var/lib/barnaby-home";
  defaultSecretsFile = "${stateDir}/secrets.env";

  tuwunelUrl = "http://127.0.0.1:6167";
  callDomain = "call.${domain}";
  familyRoomAlias = "#family:${domain}";

  # The keys each bundled skill needs from the secrets file.
  skillKeys = {
    calendar = [
      "CALDAV_URL"
      "CALDAV_USERNAME"
      "CALDAV_PASSWORD"
    ];
    weather = [ "TOMORROWIO_API_KEY" ];
    web-search = [ "KAGI_KEY" ];
  };
  requiredKeys = [
    "OPENROUTER_API_KEY"
  ]
  ++ lib.concatLists (
    lib.mapAttrsToList (
      skill: enabled: lib.optionals (enabled == true) (skillKeys.${skill} or [ ])
    ) agent.skills
  );

  barnabySoul = builtins.readFile "${barnaby}/SOUL.md";
  soul = pkgs.writeText "soul.md" (
    if agent.soul != null then
      builtins.replaceStrings [ "@name@" ] [ agent.name ] (builtins.readFile agent.soul)
    else
      builtins.replaceStrings [ "**Name:** Barnaby" ] [ "**Name:** ${agent.name}" ] barnabySoul
  );

  adminCommands = map (user: "users make-user-admin @${user}:${domain}") cfg.admins;

  # Asks Jev whether each group message is meant for the agent. The rest are
  # still recorded in its session, but don't start a turn.
  groupTrigger = pkgs.writeShellScript "group-trigger" ''
    exec ${pkgs.python3}/bin/python3 ${barnaby}/examples/group_trigger.py
  '';

  # Matrix lowercases usernames, and these are the characters it allows.
  localpart = lib.types.strMatching "[a-z0-9._=-]+";

  element = pkgs.element-web.override {
    conf = {
      default_server_config."m.homeserver" = {
        base_url = "https://${domain}";
        server_name = domain;
      };
      disable_custom_urls = true;
      disable_guests = true;
      room_directory.servers = [ domain ];
    }
    // lib.optionalAttrs cfg.calls.enable {
      element_call.use_exclusively = true;
      features.feature_group_calls = true;
    };
  };
in
{
  imports = [ barnaby.nixosModules.default ];

  options.barnabyHome = {
    domain = lib.mkOption {
      type = lib.types.str;
      example = "family.example.com";
      description = ''
        The Matrix server name. Element is served at `chat.<domain>` and calls
        at `call.<domain>`, so DNS needs records for the domain and those
        subdomains (or a wildcard).
      '';
    };

    admins = lib.mkOption {
      type = lib.types.listOf localpart;
      default = [ ];
      example = [ "dad" ];
      description = ''
        Usernames to make server admins. Each one is promoted within a minute
        of signing up.
      '';
    };

    location = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "41.88,-87.63";
      description = "Home latitude and longitude, the weather skill's default location.";
    };

    secretsFile = lib.mkOption {
      type = lib.types.str;
      default = defaultSecretsFile;
      description = ''
        Environment file with the API keys: `OPENROUTER_API_KEY`, plus
        whatever the enabled skills need. Point this somewhere else to manage
        it with agenix or sops.
      '';
    };

    calls.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to run LiveKit for voice and video calls.";
    };

    agent = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "Barnaby";
        description = "The agent's display name. It can change at any time.";
      };

      username = lib.mkOption {
        type = localpart;
        default = lib.concatStrings (
          builtins.filter (c: builtins.match "[a-z0-9._=-]" c != null) (
            lib.stringToCharacters (lib.toLower agent.name)
          )
        );
        defaultText = lib.literalMD "`name` in lowercase, without spaces or punctuation";
        description = ''
          The agent's Matrix username. The account is created on first boot,
          so changing this later has no effect.
        '';
      };

      soul = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          The agent's system prompt, where `@name@` becomes `name`. The
          default is Barnaby's own, with `name` filled in.
        '';
      };

      model = lib.mkOption {
        type = lib.types.str;
        default = "deepseek/deepseek-v4.1-flash";
        description = "The OpenRouter model the agent chats with.";
      };

      skills = lib.mkOption {
        type = lib.types.attrsOf (lib.types.either lib.types.bool lib.types.path);
        default = { };
        example = {
          weather = true;
          web-search = true;
        };
        description = ''
          Skills to add to the defaults (`image`, `transcribe`,
          `sports-scores`, and `sports-monitor`), or `false` to drop one. See
          Barnaby's docs/skills.md for the bundled skills; a path adds your own.
        '';
      };
    };
  };

  config = lib.mkMerge [
    {
      assertions = [
        {
          assertion = agent.soul != null || lib.hasInfix "**Name:** Barnaby" barnabySoul;
          message = "Barnaby's SOUL.md has no \"**Name:** Barnaby\" line to fill in anymore, so set barnabyHome.agent.soul.";
        }
      ];

      barnabyHome.agent.skills = lib.mapAttrs (_: lib.mkDefault) {
        image = true;
        transcribe = true;
        sports-scores = true;
        sports-monitor = true;
      };

      systemd.services.barnaby-home-secrets = {
        description = "Generate Barnaby Home secrets";
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.openssl ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StateDirectory = "barnaby-home";
          StateDirectoryMode = "0700";
          UMask = "0077";
        };
        script = ''
          cd ${stateDir}
          [ -s registration-token ] || openssl rand -hex 16 > registration-token
          [ -s livekit.key ] || echo "barnaby: $(openssl rand -hex 32)" > livekit.key
        ''
        + lib.optionalString (cfg.secretsFile == defaultSecretsFile) ''
          [ -e secrets.env ] || touch secrets.env
        '';
      };

      services.matrix-tuwunel = {
        enable = true;
        settings.global = {
          server_name = domain;
          address = [ "127.0.0.1" ];
          max_request_size = 50000000;
          # tuwunel appends 💕 to every new user's display name by default.
          new_user_displayname_suffix = "";

          allow_registration = true;
          registration_token_file = "/run/credentials/tuwunel.service/registration-token";
          oidc_native_auth = true;
          oidc_registration_allowed_redirect_hosts = [ "chat.${domain}" ];
          auto_join_rooms = [ familyRoomAlias ];

          # The agent registers first, and it shouldn't be the admin. Admins
          # are promoted by these commands instead, at startup and on SIGUSR2.
          grant_admin_to_first_user = false;
          admin_execute = adminCommands;
          admin_signal_execute = adminCommands;
          admin_execute_errors_ignore = true;

          well_known = {
            client = "https://${domain}";
            server = "${domain}:443";
          }
          // lib.optionalAttrs cfg.calls.enable {
            livekit_url = "https://${callDomain}/livekit/jwt";
          };
        };
      };

      systemd.services.tuwunel = {
        requires = [ "barnaby-home-secrets.service" ];
        after = [ "barnaby-home-secrets.service" ];
        serviceConfig.LoadCredential = [ "registration-token:${stateDir}/registration-token" ];
      };

      security.acme.acceptTerms = true;

      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        recommendedTlsSettings = true;
        recommendedGzipSettings = true;
        recommendedOptimisation = true;
        clientMaxBodySize = "50m";

        virtualHosts = {
          ${domain} = {
            enableACME = true;
            forceSSL = true;
            locations."/".proxyPass = tuwunelUrl;
          };

          "chat.${domain}" = {
            enableACME = true;
            forceSSL = true;
            root = element;
          };
        };
      };

      networking.firewall.allowedTCPPorts = [
        80
        443
      ];

      # Creates the agent's account and the family room once, and keeps the
      # agent's display name in sync with the config.
      systemd.services.barnaby-home-setup = {
        description = "Set up the Barnaby account and family room";
        requires = [ "tuwunel.service" ];
        after = [ "tuwunel.service" ];
        requiredBy = [ "container@barnaby.service" ];
        before = [ "container@barnaby.service" ];
        path = [
          pkgs.curl
          pkgs.jq
          pkgs.openssl
        ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
        };
        script = ''
          cd ${stateDir}

          for _ in $(seq 60); do
            curl -sf ${tuwunelUrl}/_matrix/client/versions > /dev/null && break
            sleep 1
          done

          # Secrets go through the environment, stdin, and files, never
          # arguments, which any local user can read in /proc.
          headers=/dev/null
          call() {
            curl -s -X "$1" "${tuwunelUrl}/_matrix/client/v3/$2" \
              -H 'Content-Type: application/json' -H "@$headers" -d @-
          }

          if [ ! -s agent.env ]; then
            PASSWORD=$(openssl rand -hex 24) TOKEN=$(< registration-token) PICKLE=$(openssl rand -hex 32)
            export PASSWORD TOKEN PICKLE

            request=$(jq -n \
              '{username: "${agent.username}", password: env.PASSWORD, initial_device_display_name: "Barnaby"}')
            SESSION=$(call POST register <<< "$request" | jq -r .session) && export SESSION
            response=$(jq '. + {auth: {type: "m.login.registration_token", token: env.TOKEN, session: env.SESSION}}' \
              <<< "$request" | call POST register)

            if [ "$(jq -r .access_token <<< "$response")" = null ]; then
              echo "Registering the agent failed: $response" >&2
              exit 1
            fi

            jq -r '
              "BARNABY_MATRIX_USER_ID=\(.user_id)",
              "BARNABY_MATRIX_ACCESS_TOKEN=\(.access_token)",
              "BARNABY_MATRIX_DEVICE_ID=\(.device_id)",
              "BARNABY_MATRIX_PICKLE_KEY=\(env.PICKLE)"
            ' <<< "$response" > agent.env.tmp
            mv agent.env.tmp agent.env
          fi

          user_id=$(sed -n 's/^BARNABY_MATRIX_USER_ID=//p' agent.env)
          trap 'rm -f auth-header' EXIT
          sed -n 's/^BARNABY_MATRIX_ACCESS_TOKEN=/Authorization: Bearer /p' agent.env > auth-header
          headers=auth-header

          call PUT "profile/$(jq -rn --arg u "$user_id" '$u | @uri')/displayname" \
            <<< ${lib.escapeShellArg (builtins.toJSON { displayname = agent.name; })} > /dev/null

          # Public, so tuwunel can auto-join new users, but not federated, so
          # only people with an account here can join.
          if [ ! -s room.env ]; then
            response=$(call POST createRoom <<< '{
              "name": "Family",
              "room_alias_name": "family",
              "preset": "public_chat",
              "creation_content": {"m.federate": false},
              "initial_state": [{
                "type": "m.room.encryption",
                "state_key": "",
                "content": {"algorithm": "m.megolm.v1.aes-sha2"}
              }]
            }')
            room_id=$(jq -r .room_id <<< "$response")

            if [ "$room_id" = null ]; then
              echo "Creating the family room failed: $response" >&2
              exit 1
            fi

            echo "BARNABY_MATRIX_ROOM_ID=$room_id" > room.env
          fi

          for key in ${toString (lib.unique requiredKeys)}; do
            grep -sEq "^$key=." ${cfg.secretsFile} || echo "<4>$key isn't set in ${cfg.secretsFile}." >&2
          done
        '';
      };

      services.barnaby.instances.barnaby = {
        enable = true;
        piPackage = llm-agents.packages.${pkgs.stdenv.hostPlatform.system}.pi;

        environment = {
          BARNABY_MATRIX_HOMESERVER = tuwunelUrl;
          BARNABY_PI_PROVIDER = "openrouter";
          BARNABY_PI_MODEL = agent.model;
          BARNABY_SOUL_FILE = "${soul}";
          BARNABY_GROUP_TRIGGER_SCRIPT = "${groupTrigger}";
          BARNABY_AGENT_NAME = agent.name;
          # Compacting idle sessions keeps them small, and eventually starts
          # fresh ones, which lets the old ones go quiet and become memory notes.
          BARNABY_PI_IDLE_TIMEOUT = "6h";
          BARNABY_PI_COMPACT_ON_IDLE = "true";
          TZ = if config.time.timeZone != null then config.time.timeZone else "UTC";
        }
        // lib.optionalAttrs (cfg.location != null) { WEATHER_HOME = cfg.location; };

        environmentFiles = [
          "${stateDir}/agent.env"
          "${stateDir}/room.env"
          cfg.secretsFile
        ];

        extensions.reminders = true;
        memory.enable = true;
        # sports-monitor needs sports-scores, so it goes when that does.
        skills =
          agent.skills
          // lib.optionalAttrs ((agent.skills.sports-scores or false) == false) { sports-monitor = false; };

        extraPackages = with pkgs; [
          curl
          jq
          python3
        ];
      };
    }

    (lib.mkIf (cfg.admins != [ ]) {
      # tuwunel can only promote someone after they sign up, so check for new
      # admins every minute and have it rerun its admin commands.
      systemd.services.barnaby-home-admins = {
        description = "Promote new Barnaby Home admins";
        after = [ "tuwunel.service" ];
        path = [
          pkgs.curl
          pkgs.systemd
        ];
        serviceConfig.Type = "oneshot";
        script = ''
          cd ${stateDir}
          promote=
          for user in ${toString cfg.admins}; do
            [ -e "admin-$user" ] && continue
            if curl -sf "${tuwunelUrl}/_matrix/client/v3/profile/%40$user%3A${domain}" > /dev/null; then
              touch "admin-$user"
              promote=1
            fi
          done
          [ -z "$promote" ] || systemctl kill -s USR2 tuwunel.service
        '';
      };

      systemd.timers.barnaby-home-admins = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1min";
          OnUnitActiveSec = "1min";
        };
      };
    })

    (lib.mkIf cfg.calls.enable {
      services.livekit = {
        enable = true;
        keyFile = "${stateDir}/livekit.key";
        settings = {
          port = 7880;
          rtc = {
            tcp_port = 7881;
            port_range_start = 50000;
            port_range_end = 51000;
            use_external_ip = true;
          };
          turn = {
            enabled = true;
            domain = callDomain;
            udp_port = 3478;
            tls_port = 5349;
            cert_file = "/run/credentials/livekit.service/turn-cert";
            key_file = "/run/credentials/livekit.service/turn-key";
          };
          # lk-jwt-service creates rooms for local users.
          room.auto_create = false;
        };
      };

      systemd.services.livekit = {
        requires = [ "barnaby-home-secrets.service" ];
        wants = [ "acme-${callDomain}.service" ];
        after = [
          "barnaby-home-secrets.service"
          "acme-${callDomain}.service"
        ];
        # LiveKit exits cleanly when it can't reach STUN to find its public IP
        # (DNS not up yet, say), so on-failure wouldn't bring it back.
        serviceConfig.Restart = lib.mkForce "always";
        serviceConfig.LoadCredential = [
          "turn-cert:/var/lib/acme/${callDomain}/fullchain.pem"
          "turn-key:/var/lib/acme/${callDomain}/key.pem"
        ];
      };

      services.lk-jwt-service = {
        enable = true;
        livekitUrl = "wss://${callDomain}/livekit/sfu";
        keyFile = "${stateDir}/livekit.key";
      };

      systemd.services.lk-jwt-service = {
        requires = [ "barnaby-home-secrets.service" ];
        after = [ "barnaby-home-secrets.service" ];
        environment.LIVEKIT_FULL_ACCESS_HOMESERVERS = domain;
      };

      security.acme.certs.${callDomain}.reloadServices = [ "livekit.service" ];

      services.nginx.virtualHosts.${callDomain} = {
        enableACME = true;
        forceSSL = true;
        locations."/livekit/jwt/".proxyPass =
          "http://127.0.0.1:${toString config.services.lk-jwt-service.port}/";
        locations."/livekit/sfu/" = {
          proxyPass = "http://127.0.0.1:7880/";
          proxyWebsockets = true;
          extraConfig = ''
            proxy_read_timeout 120s;
            proxy_send_timeout 120s;
            proxy_buffering off;
          '';
        };
      };

      networking.firewall = {
        allowedTCPPorts = [
          7881 # LiveKit media over TCP
          5349 # TURN over TLS
        ];
        allowedUDPPorts = [ 3478 ]; # TURN
        allowedUDPPortRanges = [
          {
            from = 50000;
            to = 51000;
          }
        ];
      };
    })
  ];
}
