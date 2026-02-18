{
  lib,
  config,
  pkgs,
  options,
  ...
}:

let

  cfg = config.services.openproject;
  opt = options.services.openproject;

  user = "openproject";
  group = "openproject";
  dataDir = "/var/lib/openproject";

  # An IPv6 address needs brackets in a URL, and wherever a port follows it
  # (nginx, caddy, Dalli).
  bracketIPv6 = host: if lib.hasInfix ":" host && !lib.hasPrefix "[" host then "[${host}]" else host;
  hostPort = host: port: "${bracketIPv6 host}:${toString port}";

  memcachedServer =
    let
      mc = config.services.memcached;
    in
    hostPort (lib.head (lib.splitString "," mc.listen)) mc.port;

  listeningAddress = hostPort cfg.settings.BINDING cfg.settings.PORT;

  configEnv = lib.concatMapAttrs (
    name: value:
    lib.optionalAttrs (value != null) {
      ${name} = if lib.isBool value then lib.boolToString value else toString value;
    }
  ) cfg.settings;

  bundle = lib.getExe' cfg.package.rubyEnv.wrappedRuby "bundle";

  isDatabaseUnixSocket = lib.hasPrefix "/" cfg.database.host;

  # The password, if any, is passed through PGPASSWORD (read by libpq), so it
  # never has to be embedded in, or escaped for, the connection URL.
  databaseUrl =
    pool:
    let
      # The socket directory goes into the query unescaped, like upstream's
      # documented `?host=/var/run/postgresql`.
      params = lib.concatStringsSep "&" (
        lib.optionals isDatabaseUnixSocket [
          "host=${cfg.database.host}"
          "username=${lib.strings.escapeURL cfg.database.user}"
        ]
        ++ [
          "pool=${toString pool}"
          "encoding=unicode"
          "reconnect=true"
        ]
      );
      authority = lib.optionalString (!isDatabaseUnixSocket) (
        "${lib.strings.escapeURL cfg.database.user}@${bracketIPv6 cfg.database.host}"
        + lib.optionalString (cfg.database.port != null) ":${toString cfg.database.port}"
      );
    in
    "postgres://${authority}/${lib.strings.escapeURL cfg.database.name}?${params}";

  # Puma serves each request on one of web.max_threads threads, and each needs
  # a connection. Upstream also raises the pool to this by itself
  # (config/initializers/database_pool_size.rb).
  webDatabaseUrl = databaseUrl (cfg.settings.OPENPROJECT_WEB_MAX__THREADS + 1);

  # GoodJob needs one connection per execution thread, one for LISTEN/NOTIFY
  # and GoodJob::SharedExecutor::MAX_THREADS (2) for its utility threads.
  goodJobUtilityConnections = 3;
  workerDatabaseUrl = databaseUrl (cfg.worker.maxThreads + goodJobUtilityConnections);

  defaultSecretKeyBaseFile = "${dataDir}/secrets/secret-key-base";
  needsGenCredentialsUnit = cfg.secretKeyBaseFile == null;

  credentials = {
    SECRET_KEY_BASE = lib.defaultTo defaultSecretKeyBaseFile cfg.secretKeyBaseFile;
  }
  // lib.optionalAttrs (cfg.database.passwordFile != null) {
    PGPASSWORD = cfg.database.passwordFile;
  };
  seederCredentials =
    credentials
    // lib.optionalAttrs (cfg.initialAdminPasswordFile != null) {
      OPENPROJECT_SEED_ADMIN_USER_PASSWORD = cfg.initialAdminPasswordFile;
    };
  imapCredentials = credentials // {
    IMAP_PASSWORD = cfg.imap.passwordFile;
  };

  loadCredentialsIntoEnv = lib.concatMapAttrsStringSep "\n" (
    name: _: ''export ${name}="$(systemd-creds cat ${name})"''
  );
  loadCredentials = lib.mapAttrsToList (name: path: "${name}:${path}");

  imapArgs = lib.mapAttrsToList (name: value: lib.escapeShellArg "${name}=${toString value}") (
    lib.filterAttrs (_: value: value != null) (
      {
        inherit (cfg.imap) host port folder;
        username = cfg.imap.user;
        ssl = lib.boolToString cfg.imap.ssl;
      }
      // cfg.imap.settings
    )
  );

  openproject-cli = pkgs.writeShellApplication {
    name = "openproject";

    text =
      let
        command = pkgs.writeShellScript "openproject-unwrapped" ''
          # Transient units get a bare PATH
          export PATH=${
            lib.makeBinPath [
              config.systemd.package
              pkgs.coreutils
            ]
          }:$PATH
          ${loadCredentialsIntoEnv credentials}
          # Accept upstream's packaged-install syntax: `openproject run <cmd>`
          if [ "''${1:-}" = run ]; then
            shift
          fi
          exec ${bundle} exec "$@"
        '';
      in
      ''
        if [ "$#" -eq 0 ]; then
          echo "usage: openproject [run] <command> [args...]" >&2
          echo "  e.g. openproject rails console" >&2
          echo "       openproject rake db:migrate" >&2
          exit 1
        fi

        if [ -t 0 ] && [ -t 1 ]; then
          io=--pty
        else
          io=--pipe
        fi

        exec ${lib.getExe' config.systemd.package "systemd-run"} \
          ${lib.escapeShellArgs (map (c: "--property=LoadCredential=${c}") (loadCredentials credentials))} \
          ${lib.escapeShellArgs (map (f: "--property=EnvironmentFile=${f}") cfg.environmentFiles)} \
          ${
            lib.escapeShellArgs (
              lib.mapAttrsToList (name: value: "--setenv=${name}=${value}") (
                configEnv // { DATABASE_URL = webDatabaseUrl; }
              )
            )
          } \
          --uid=${user} \
          --gid=${group} \
          --working-directory=${cfg.package} \
          --property=PrivateTmp=yes \
          "$io" \
          --wait \
          --collect \
          --service-type=exec \
          --quiet \
          -- \
          ${command} "$@"
      '';
  };

  defaultServiceConfig = {
    User = user;
    Group = group;
    WorkingDirectory = cfg.package;
    StateDirectory = [
      "openproject"
      "openproject/files"
      "openproject/secrets"
    ];
    StateDirectoryMode = "0750";
    EnvironmentFile = cfg.environmentFiles;
    # Service hardening
    AmbientCapabilities = "";
    CapabilityBoundingSet = "";
    # ProtectClock adds DeviceAllow=char-rtc r
    DeviceAllow = "";
    DevicePolicy = "closed";
    LockPersonality = true;
    # Rails enables Ruby's YJIT compiler, which writes executable memory.
    MemoryDenyWriteExecute = false;
    NoNewPrivileges = true;
    RemoveIPC = true;
    PrivateDevices = true;
    PrivateMounts = true;
    PrivateTmp = true;
    PrivateUsers = true;
    ProtectClock = true;
    ProtectHome = true;
    ProtectHostname = true;
    ProtectSystem = "strict";
    ProtectControlGroups = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectProc = "invisible";
    ProcSubset = "pid";
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "~@resources"
    ];
    UMask = "0077";
  };

  seederUnit = lib.optional cfg.automaticMigrations "openproject-seeder.service";
  credentialsUnit = lib.optional needsGenCredentialsUnit "openproject-init-credentials.service";
  databaseUnit =
    if cfg.database.createLocally then [ "postgresql.target" ] else [ "network-online.target" ];
  memcachedUnit = lib.optional cfg.memcached.createLocally "memcached.service";

in
{
  meta = {
    maintainers = with lib.maintainers; [
      bendlas
      onny
    ];
  };

  options.services.openproject = {

    enable = lib.mkEnableOption "OpenProject, a web-based project management application";

    package = lib.mkPackageOption pkgs "openproject" { };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to configure a local PostgreSQL server and database for OpenProject.
          The connection is made through a unix socket with peer authentication.
        '';
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "/run/postgresql";
        example = "db.example.com";
        description = ''
          Hostname or address of the PostgreSQL server. An absolute path is
          interpreted as the directory of a unix socket.
        '';
      };

      port = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        example = 5432;
        description = "Port of the PostgreSQL server. Ignored for unix sockets.";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "openproject";
        description = "Name of the OpenProject database.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "openproject";
        description = "Database user for OpenProject.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.externalPath;
        default = null;
        example = "/run/secrets/openproject-db-password";
        description = ''
          File containing the password for {option}`${opt.database.user}`.
          It is loaded through systemd credentials and passed to libpq as
          {env}`PGPASSWORD`, so it never ends up in the Nix store.
        '';
      };
    };

    automaticMigrations = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to run `rake db:migrate` and then `rake db:seed` before
        OpenProject starts.
        Both tasks are idempotent; upstream's packaged installs and container
        images run them on every start as well.

        If disabled, run them yourself with `openproject rake db:migrate` and
        `openproject rake db:seed`
        after the first install and after every upgrade.
      '';
    };

    webserver = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "nginx"
          "caddy"
        ]
      );
      default = "nginx";
      example = "caddy";
      description = ''
        Which reverse proxy to configure in front of OpenProject, or `null`
        to configure none and set up a proxy yourself. OpenProject listens on
        {option}`${opt.settings}.BINDING`:{option}`${opt.settings}.PORT` and
        expects static files under {file}`''${package}/public` to be served
        directly.

        Further configuration can be done through
        [](#opt-services.nginx.virtualHosts) or
        [](#opt-services.caddy.virtualHosts).

        OpenProject expects to be reached over HTTPS: by default it redirects
        plain HTTP requests to HTTPS and marks its cookies as secure. Caddy
        obtains a certificate by itself. For nginx, enable TLS on the virtual
        host, for example with
        `services.nginx.virtualHosts.<name>.enableACME = true` and
        `forceSSL = true`. To serve OpenProject over plain HTTP, set
        `OPENPROJECT_HTTPS = false` in {option}`${opt.settings}`.
      '';
    };

    memcached.createLocally = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether to run a local memcached instance and use it as the Rails
        cache, connecting over TCP to
        {option}`services.memcached.listen` and {option}`services.memcached.port`.

        If disabled, OpenProject falls back to its file-based cache unless
        configured otherwise through {option}`${opt.settings}`. That cache
        lives in each service's private {file}`/tmp`, so the web server and the
        background worker don't share it and it is emptied when they restart.
      '';
    };

    worker.maxThreads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 20;
      description = ''
        Number of threads the background job worker (GoodJob) uses to run
        jobs. The worker's database connection pool is sized to match.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = lib.types.attrsOf (
          lib.types.nullOr (
            lib.types.oneOf [
              lib.types.str
              lib.types.bool
              lib.types.int
              lib.types.path
            ]
          )
        );
        options = {
          OPENPROJECT_HOST__NAME = lib.mkOption {
            type = lib.types.str;
            default = "localhost";
            example = "openproject.example.com";
            description = ''
              Host name under which OpenProject is reached. Also used as the
              name of the reverse proxy's virtual host.
            '';
          };
          PORT = lib.mkOption {
            type = lib.types.port;
            default = 6346;
            description = "Port for the puma web server to listen on.";
          };
          BINDING = lib.mkOption {
            type = lib.types.str;
            default = "127.0.0.1";
            description = "Address for the puma web server to listen on.";
          };
          OPENPROJECT_WEB_MAX__THREADS = lib.mkOption {
            type = lib.types.ints.positive;
            default = 16;
            description = ''
              Maximum number of threads each puma worker serves requests on.
              The web services' database connection pool is sized to match.
            '';
          };
        };
      };
      default = { };
      example = {
        OPENPROJECT_HOST__NAME = "openproject.example.com";
        OPENPROJECT_DEFAULT__LANGUAGE = "de";
        OPENPROJECT_WEB_WORKERS = 4;
      };
      description = ''
        Environment variables used to configure OpenProject. See the
        [upstream documentation](https://www.openproject.org/docs/installation-and-operations/configuration/environment/)
        for the available settings. Run `openproject rake setting:available_envs`
        to list every variable this version understands.

        Values set here end up in the world-readable Nix store. Put secrets,
        such as {env}`OPENPROJECT_SMTP__PASSWORD`, in a file listed in
        {option}`${opt.environmentFiles}` instead.
      '';
    };

    environmentFiles = lib.mkOption {
      type = lib.types.listOf lib.types.externalPath;
      default = [ ];
      example = [ "/run/secrets/openproject.env" ];
      description = ''
        Files with additional environment variables in the format of
        systemd's `EnvironmentFile=`, passed to every OpenProject service and
        to the `openproject` command. Use this for secret settings.
      '';
    };

    secretKeyBaseFile = lib.mkOption {
      type = lib.types.nullOr lib.types.externalPath;
      default = null;
      example = "/run/secrets/openproject-secret-key-base";
      description = ''
        File containing the secret key base used to sign cookies and encrypt
        data at rest. One way to create one is `openssl rand -hex 64`.

        The file is loaded through systemd credentials, so it does not need to
        be readable by the openproject user.

        If `null`, a key is generated on first start at
        {file}`${defaultSecretKeyBaseFile}`.
      '';
    };

    initialAdminPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.externalPath;
      default = null;
      example = "/run/secrets/openproject-admin-password";
      description = ''
        File containing the password given to the `admin` account when the
        database is first seeded. If `null`, the password is `admin` and must
        be changed on first login. Has no effect once the database is seeded.
      '';
    };

    imap = {
      enable = lib.mkEnableOption "periodically fetching mail from an IMAP mailbox to create and update work packages";

      host = lib.mkOption {
        type = lib.types.str;
        example = "imap.example.com";
        description = "IMAP server to fetch mail from.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 993;
        description = "Port of the IMAP server.";
      };

      ssl = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to connect to the IMAP server over TLS.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        example = "openproject@example.com";
        description = "User name for the IMAP server.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.externalPath;
        example = "/run/secrets/openproject-imap-password";
        description = ''
          File containing the password for {option}`${opt.imap.user}`,
          loaded through systemd credentials.
        '';
      };

      folder = lib.mkOption {
        type = lib.types.str;
        default = "INBOX";
        description = "Mailbox folder to fetch mail from.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "5min";
        description = ''
          How long to wait between fetches, in the format of
          {manpage}`systemd.time(7)`.
        '';
      };

      settings = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.nullOr (
            lib.types.oneOf [
              lib.types.str
              lib.types.bool
              lib.types.int
            ]
          )
        );
        default = { };
        example = {
          project = "support";
          unknown_user = "create";
          move_on_success = "processed";
        };
        description = ''
          Further arguments passed to `rake redmine:email:receive_imap`, such
          as `project`, `type`, `unknown_user` or `move_on_success`. See
          [upstream's documentation](https://www.openproject.org/docs/installation-and-operations/configuration/incoming-emails/).
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = cfg.database.createLocally -> isDatabaseUnixSocket;
        message = ''
          services.openproject.database.host must be a unix socket path when
          services.openproject.database.createLocally is enabled.
        '';
      }
      {
        assertion = cfg.database.createLocally -> cfg.database.user == user;
        message = ''
          services.openproject.database.user must be "${user}" when
          services.openproject.database.createLocally is enabled, since the
          local connection authenticates through peer authentication.
        '';
      }
      {
        assertion = cfg.database.createLocally -> cfg.database.passwordFile == null;
        message = ''
          services.openproject.database.passwordFile has no effect with
          services.openproject.database.createLocally, which uses peer
          authentication over a unix socket.
        '';
      }
      {
        assertion = cfg.memcached.createLocally -> !config.services.memcached.enableUnixSocket;
        message = ''
          services.openproject.memcached.createLocally connects to memcached
          over TCP, but services.memcached.enableUnixSocket turns TCP off.
          memcached creates its socket accessible only to its own user, so
          OpenProject can't use it. Disable one of the two options.
        '';
      }
    ];

    services.openproject.settings = {
      RAILS_ENV = "production";
      BUNDLE_WITHOUT = "development:test";
      # Bundler wants a writable home; this is inside each unit's PrivateTmp.
      BUNDLE_USER_HOME = "/tmp/bundle";
      OPENPROJECT_GOOD_JOB_MAX_THREADS = cfg.worker.maxThreads;
      OPENPROJECT_ATTACHMENTS__STORAGE__PATH = lib.mkDefault "${dataDir}/files";
      LD_PRELOAD = lib.mkDefault "${lib.getLib pkgs.jemalloc}/lib/libjemalloc.so";
    }
    // lib.optionalAttrs cfg.memcached.createLocally {
      OPENPROJECT_RAILS_CACHE_STORE = lib.mkDefault "memcache";
      OPENPROJECT_CACHE__MEMCACHE__SERVER = lib.mkDefault memcachedServer;
      OPENPROJECT_CACHE__NAMESPACE = lib.mkDefault "openproject";
    };

    systemd.services.openproject-init-credentials = lib.mkIf needsGenCredentialsUnit {
      description = "OpenProject secret key generation";
      script = ''
        if ! test -s ${defaultSecretKeyBaseFile}; then
          ${lib.getExe pkgs.openssl} rand -hex 64 > ${defaultSecretKeyBaseFile}
        fi
      '';
      serviceConfig = defaultServiceConfig // {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };

    systemd.services.openproject-seeder = lib.mkIf cfg.automaticMigrations {
      description = "OpenProject database migration and seeding";
      script = ''
        ${loadCredentialsIntoEnv seederCredentials}
        # Two separate runs, as upstream's postinstall does: seeding in the
        # same process as the migrations sees stale column information.
        ${bundle} exec rake db:migrate
        ${bundle} exec rake db:seed
      '';
      serviceConfig = defaultServiceConfig // {
        Type = "oneshot";
        RemainAfterExit = true;
        LoadCredential = loadCredentials seederCredentials;
        TimeoutStartSec = "infinity";
      };
      environment = configEnv // {
        DATABASE_URL = webDatabaseUrl;
      };
      wants = databaseUnit ++ memcachedUnit;
      requires = credentialsUnit;
      after = databaseUnit ++ credentialsUnit ++ memcachedUnit;
    };

    systemd.services.openproject-web = {
      description = "OpenProject web server";
      script = ''
        ${loadCredentialsIntoEnv credentials}
        exec ${bundle} exec rails server -u puma
      '';
      serviceConfig = defaultServiceConfig // {
        LoadCredential = loadCredentials credentials;
        Restart = "on-failure";
        RestartSec = 10;
      };
      environment = configEnv // {
        DATABASE_URL = webDatabaseUrl;
      };
      wants = databaseUnit ++ memcachedUnit;
      requires = seederUnit ++ credentialsUnit;
      after = seederUnit ++ credentialsUnit ++ databaseUnit ++ memcachedUnit;
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services.openproject-worker = {
      description = "OpenProject background job worker";
      script = ''
        ${loadCredentialsIntoEnv credentials}
        exec ${bundle} exec good_job start
      '';
      serviceConfig = defaultServiceConfig // {
        LoadCredential = loadCredentials credentials;
        Restart = "on-failure";
        RestartSec = 10;
      };
      environment = configEnv // {
        DATABASE_URL = workerDatabaseUrl;
      };
      wants = databaseUnit ++ memcachedUnit;
      requires = seederUnit ++ credentialsUnit;
      after = seederUnit ++ credentialsUnit ++ databaseUnit ++ memcachedUnit;
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services.openproject-imap = lib.mkIf cfg.imap.enable {
      description = "OpenProject incoming mail fetcher";
      script = ''
        ${loadCredentialsIntoEnv imapCredentials}
        # The rake task reads its options from the environment; passing the
        # password that way keeps it off the command line.
        export password="$IMAP_PASSWORD"
        exec ${bundle} exec rake redmine:email:receive_imap \
          ${lib.concatStringsSep " " imapArgs}
      '';
      serviceConfig = defaultServiceConfig // {
        Type = "oneshot";
        LoadCredential = loadCredentials imapCredentials;
      };
      environment = configEnv // {
        DATABASE_URL = webDatabaseUrl;
      };
      wants = databaseUnit ++ memcachedUnit;
      requires = seederUnit ++ credentialsUnit;
      after = seederUnit ++ credentialsUnit ++ databaseUnit ++ memcachedUnit;
    };

    systemd.timers.openproject-imap = lib.mkIf cfg.imap.enable {
      description = "Periodically fetch mail into OpenProject";
      timerConfig = {
        OnActiveSec = "1min";
        OnUnitInactiveSec = cfg.imap.interval;
      };
      wantedBy = [ "timers.target" ];
    };

    services.memcached = lib.mkIf cfg.memcached.createLocally {
      enable = true;
    };

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
    };

    services.nginx = lib.mkIf (cfg.webserver == "nginx") {
      enable = true;
      virtualHosts."${cfg.settings.OPENPROJECT_HOST__NAME}" = {
        root = "${cfg.package}/public";
        # OpenProject enforces its own attachment size limit, which admins can
        # raise at runtime past services.nginx.clientMaxBodySize. nginx checks
        # the limit where try_files runs, so it can't go in @openproject.
        extraConfig = ''
          client_max_body_size 0;
        '';
        locations."/" = {
          tryFiles = "$uri @openproject";
        };
        locations."@openproject" = {
          proxyPass = "http://${listeningAddress}";
          recommendedProxySettings = true;
        };
      };
    };

    services.caddy = lib.mkIf (cfg.webserver == "caddy") {
      enable = true;
      virtualHosts."${cfg.settings.OPENPROJECT_HOST__NAME}" = {
        extraConfig = ''
          root * ${cfg.package}/public

          @notStatic {
            not file
          }
          reverse_proxy @notStatic ${listeningAddress}

          file_server
        '';
      };
    };

    environment.systemPackages = [ openproject-cli ];

    users = {
      groups.${group} = { };
      users.${user} = {
        isSystemUser = true;
        inherit group;
        home = dataDir;
      };
    };

  };
}
