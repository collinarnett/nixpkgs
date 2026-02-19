{ pkgs, ... }:
let
  adminPassword = "Correct-horse-battery-1";

  # Log in through the web form as the seeded admin, then create a work
  # package and attach a file to it through API v3 using that session. The
  # attachment is larger than services.nginx.clientMaxBodySize (10m).
  smokeTest = pkgs.writeShellApplication {
    name = "openproject-smoke-test";
    runtimeInputs = with pkgs; [
      curl
      gnugrep
      gnused
      jq
    ];
    text = ''
      base=http://localhost
      jar=$(mktemp)
      curlj() { curl -sSf -c "$jar" -b "$jar" "$@"; }
      token() { grep -o 'name="authenticity_token" value="[^"]*"' | head -1 | sed 's/.*value="//;s/"$//'; }

      t=$(curlj "$base/login" | token)
      curlj -o /dev/null -L --data-urlencode "authenticity_token=$t" \
        -d username=admin --data-urlencode "password=${adminPassword}" "$base/login"

      # Logged in: /my/page renders instead of redirecting to /login
      test "$(curlj -o /dev/null -w '%{http_code}' "$base/my/page")" = 200

      csrf=$(curlj "$base/projects" | grep -o 'name="csrf-token" content="[^"]*"' | sed 's/.*content="//;s/"$//')
      api() {
        curlj -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $csrf" \
          -H 'Content-Type: application/json' "$@"
      }

      test "$(api "$base/api/v3/users/me" | jq -r .login)" = admin

      wp=$(api -X POST -d '{"subject":"Created by the NixOS test","_links":{"type":{"href":"/api/v3/types/1"}}}' \
        "$base/api/v3/projects/demo-project/work_packages")
      test "$(jq -r ._type <<< "$wp")" = WorkPackage
      id=$(jq -r .id <<< "$wp")

      { echo "attached by the NixOS test"; head -c 12M /dev/zero | tr "\\0" x; } > /tmp/hello.txt
      attachment=$(curlj -H 'X-Requested-With: XMLHttpRequest' -H "X-CSRF-Token: $csrf" \
        -F 'metadata={"fileName":"hello.txt"};type=application/json' \
        -F 'file=@/tmp/hello.txt;type=text/plain' \
        "$base/api/v3/work_packages/$id/attachments")
      test "$(jq -r ._type <<< "$attachment")" = Attachment
    '';
  };
in
{
  name = "openproject";
  meta = with pkgs.lib.maintainers; {
    maintainers = [
      bendlas
      onny
    ];
  };

  nodes.machine =
    { ... }:
    {
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;

      services.openproject = {
        enable = true;
        initialAdminPasswordFile = "/etc/openproject-admin-password";
        settings = {
          OPENPROJECT_HTTPS = false;
          OPENPROJECT_HSTS = false;
          OPENPROJECT_SEED_ADMIN_USER_PASSWORD_RESET = false;
          # In KiB, above the 12 MiB attachment the smoke test uploads
          OPENPROJECT_ATTACHMENT__MAX__SIZE = 16384;
        };
      };

      environment.etc."openproject-admin-password".text = adminPassword;

      # The first API requests are slow under emulation; don't let nginx cut
      # them off after its default 60 seconds.
      services.nginx.virtualHosts.localhost.locations."@openproject".extraConfig =
        "proxy_read_timeout 300s;";

      environment.systemPackages = [
        pkgs.socat
        smokeTest
      ];
    };

  testScript = ''
    machine.start()

    with subtest("Secret key is generated on first start"):
        machine.wait_for_unit("openproject-init-credentials.service")
        machine.succeed("test $(stat -c %U:%a /var/lib/openproject/secrets/secret-key-base) = openproject:600")
        machine.succeed("test $(wc -c < /var/lib/openproject/secrets/secret-key-base) = 129")

    with subtest("Database is migrated and seeded"):
        machine.wait_for_unit("openproject-seeder.service", timeout=3600)

    with subtest("Web and worker services are running"):
        machine.wait_for_unit("openproject-web.service")
        machine.wait_for_unit("openproject-worker.service")
        machine.wait_for_open_port(6346, timeout=3600)
        machine.succeed("ss -Htln 'sport = :6346' | grep -q 127.0.0.1:6346")
        machine.fail("ss -Htln 'sport = :6346' | grep -vq 127.0.0.1:6346")
        machine.wait_for_unit("nginx.service")
        machine.wait_for_open_port(80)
        login = machine.wait_until_succeeds("curl -sSfL http://localhost/login", timeout=900)
        assert "OpenProject" in login, "login page does not mention OpenProject"

    with subtest("The openproject command runs with the service's credentials and settings"):
        secret = machine.succeed("cat /var/lib/openproject/secrets/secret-key-base").strip()
        assert machine.succeed("openproject run printenv SECRET_KEY_BASE").strip() == secret
        assert "pool=" in machine.succeed("openproject printenv DATABASE_URL")

    with subtest("Admin can log in and create a work package"):
        machine.succeed("openproject-smoke-test")

    with subtest("Attachments are stored in the state directory"):
        machine.succeed("grep -rl 'attached by the NixOS test' /var/lib/openproject/files")

    with subtest("The package's tmp/ is each unit's private /tmp"):
        package = machine.succeed("systemctl show -p WorkingDirectory --value openproject-web").strip()
        machine.succeed(f"test $(readlink {package}/tmp) = /tmp")
        machine.fail(f"test -e {package}/files")
        machine.succeed("openproject touch tmp/nixos-test")
        machine.fail("test -e /tmp/nixos-test")

    with subtest("Background jobs run without exhausting the database pool"):
        machine.wait_until_succeeds(
            "test $(runuser -u postgres -- psql -d openproject -At -c "
            "\"select count(*) from good_jobs where finished_at > now() - interval '30 minutes'\") -gt 0",
            timeout=900,
        )
        machine.succeed(
            "test $(runuser -u postgres -- psql -d openproject -At -c "
            "\"select count(*) from good_jobs where error is not null\") = 0"
        )
        machine.fail("journalctl -u openproject-worker | grep ConnectionTimeoutError")
        # 20 GoodJob threads (the default) plus its 3 utility connections
        machine.succeed(
            "systemctl show openproject-worker -p Environment | grep -o 'pool=[0-9]*' | grep -x pool=23"
        )

    with subtest("Rails cache is stored in memcached"):
        machine.wait_until_succeeds(
            "echo stats | socat - TCP:127.0.0.1:11211 "
            "| grep -E 'STAT total_items [1-9]'",
            timeout=300,
        )
  '';
}
