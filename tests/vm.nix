# Boots the stack without network access. ACME can't issue certificates, so
# nginx and LiveKit run on its self-signed placeholders.
{ pkgs, module }:
pkgs.testers.runNixOSTest {
  name = "barnaby-home";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ module ];
      barnabyHome = {
        domain = "barntest.test";
        admins = [ "alice" ];
        agent.name = "Mr. Wiggles";
        agent.skills = {
          weather = true;
          calendar = true;
        };
        # A custom path, with a password that isn't valid shell.
        secretsFile = "/etc/barnaby-secrets.env";
      };
      environment.etc."barnaby-secrets.env".text = ''
        OPENROUTER_API_KEY=sk-test
        CALDAV_URL=https://caldav.example.com/
        CALDAV_USERNAME=alice
        CALDAV_PASSWORD=a|b (c) "d
      '';
      virtualisation.memorySize = 2048;
      # No STUN server to find a public IP.
      services.livekit.settings.rtc.use_external_ip = lib.mkForce false;
      networking.hosts."127.0.0.1" = [
        "barntest.test"
        "chat.barntest.test"
        "call.barntest.test"
      ];
    };

  testScript = ''
    import json

    hs = "http://127.0.0.1:6167/_matrix/client/v3"

    def call(method, path, body=None, token=None):
        auth = f"-H 'Authorization: Bearer {token}'" if token else ""
        data = f"-d '{json.dumps(body)}'" if body is not None else ""
        return json.loads(machine.succeed(f"curl -s -X {method} {auth} {data} {hs}/{path}"))

    def register(username):
        body = {"username": username, "password": "correct horse battery"}
        session = call("POST", "register", body)["session"]
        token = machine.succeed("cat /var/lib/barnaby-home/registration-token").strip()
        auth = {"type": "m.login.registration_token", "token": token, "session": session}
        return call("POST", "register", body | {"auth": auth})["access_token"]

    def joined_rooms(token):
        return call("GET", "joined_rooms", token=token)["joined_rooms"]

    with subtest("agent account and family room"):
        machine.wait_for_unit("barnaby-home-setup.service")
        machine.succeed("grep -qx 'BARNABY_MATRIX_USER_ID=@mr.wiggles:barntest.test' /var/lib/barnaby-home/agent.env")
        profile = call("GET", "profile/%40mr.wiggles%3Abarntest.test")
        assert profile["displayname"] == "Mr. Wiggles", profile
        family = machine.succeed("sed -n 's/^BARNABY_MATRIX_ROOM_ID=//p' /var/lib/barnaby-home/room.env").strip()
        assert call("GET", "directory/room/%23family%3Abarntest.test")["room_id"] == family

    with subtest("missing keys are reported"):
        setup_log = machine.succeed("journalctl -u barnaby-home-setup")
        assert "TOMORROWIO_API_KEY isn't set" in setup_log, setup_log
        assert "OPENROUTER_API_KEY" not in setup_log, setup_log
        assert "CALDAV" not in setup_log, setup_log

    with subtest("agent starts with its soul"):
        machine.wait_for_unit("container@barnaby.service")
        machine.wait_until_succeeds("journalctl -M barnaby -u barnaby | grep -q 'starting matrix sync'", timeout=120)
        machine.succeed("systemctl -M barnaby is-enabled barnaby-memory.timer")
        machine.succeed("grep -q 'Mr. Wiggles' $(systemctl -M barnaby show barnaby -p Environment --value | tr ' ' '\\n' | sed -n 's/^BARNABY_SOUL_FILE=//p')")

    with subtest("agent can write skills"):
        machine.succeed("test -f /var/lib/barnaby/skills/skill-writer/SKILL.md")
        as_agent = "nixos-container run barnaby -- su -s /bin/sh barnaby -c"
        machine.succeed(f"{as_agent} 'git --version && rg --version'")
        machine.succeed(f"{as_agent} 'nix eval --raw nixpkgs#hello.pname' | grep -q hello")

    with subtest("new users join the family room, and admins are promoted"):
        alice = register("alice")
        assert family in joined_rooms(alice)
        bob = register("bob")
        assert family in joined_rooms(bob)

        admin_room = call("GET", "directory/room/%23admins%3Abarntest.test")["room_id"]
        machine.succeed("systemctl start barnaby-home-admins.service")
        machine.wait_until_succeeds(f"curl -s -H 'Authorization: Bearer {alice}' {hs}/joined_rooms | grep -q '{admin_room}'", timeout=30)
        assert admin_room not in joined_rooms(bob)

    with subtest("web"):
        machine.wait_for_unit("nginx.service")
        machine.succeed("curl -skf https://barntest.test/.well-known/matrix/client | grep -q call.barntest.test")
        machine.succeed("curl -skf https://chat.barntest.test/config.json | grep -q barntest.test")

    with subtest("calls"):
        machine.wait_for_unit("livekit.service")
        machine.wait_for_open_port(7880)
        machine.wait_for_unit("lk-jwt-service.service")
        machine.succeed("curl -skf https://call.barntest.test/livekit/sfu/")
  '';
}
