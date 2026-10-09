"""Sets up, configures, installs, and deploys a Barnaby Home server.

The barnaby-home launcher runs this in Docker, with the project directory
mounted read-write and the user's home directory read-only, both at the same
paths as on the host.
"""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import questionary

TEMPLATE = Path(os.environ["BARNABY_HOME_TEMPLATE"])
ZONEINFO = Path(os.environ["BARNABY_HOME_ZONEINFO"])
HOST_HOME = Path(os.environ.get("HOST_HOME") or Path.home())

STATE = Path(".barnaby-home")
CONFIG = Path("configuration.nix")
SECRETS = Path("secrets.env")
FACTER = Path("facter.json")
KNOWN_HOSTS = Path("known_hosts")
REMOTE_STATE = "/var/lib/barnaby-home"

# The keys each optional skill needs in secrets.env, and which of them aren't
# secret (so they're asked without hiding what's typed).
SKILLS = {
    "weather": ["TOMORROWIO_API_KEY"],
    "web-search": ["KAGI_KEY"],
    "calendar": ["CALDAV_URL", "CALDAV_USERNAME", "CALDAV_PASSWORD"],
}
PLAIN_KEYS = {"CALDAV_URL", "CALDAV_USERNAME"}

# Matrix usernames, as barnabyHome.admins and agent.username allow them.
LOCALPART = re.compile(r"[a-z0-9._=-]+")


class Stop(Exception):
    """Ends the command with a message, and no traceback."""


def run(*cmd, **kwargs):
    return subprocess.run(cmd, check=True, **kwargs)


def ask(question):
    """Ctrl-C raises KeyboardInterrupt, rather than returning None."""
    return question.unsafe_ask()


def expand(path):
    """Expands ~ to the home directory on the host, which is mounted at the
    same path."""
    if path == "~" or path.startswith("~/"):
        return str(HOST_HOME) + path[1:]
    return path


def unexpand(path):
    home = str(HOST_HOME)
    return "~" + path[len(home) :] if path.startswith(home + "/") else path


def load_state():
    state = {}
    if STATE.exists():
        for line in STATE.read_text().splitlines():
            words = shlex.split(line, comments=True)
            if words:
                key, _, value = words[0].partition("=")
                state[key] = value
    return state


def save_state(state):
    STATE.write_text(
        "# Written by ./barnaby-home configure.\n"
        + "".join(f"{key}={shlex.quote(value)}\n" for key, value in state.items())
    )


def require_state():
    state = load_state()
    if "SSH_HOST" not in state:
        raise Stop("Run ./barnaby-home configure first.")
    return state


def parse_ssh(command):
    """Takes the user, host, port, and key out of an ssh command line."""
    words = shlex.split(command)
    if words[:1] == ["ssh"]:
        words = words[1:]

    key = port = target = None
    while words:
        word = words.pop(0)
        if word in ("-i", "-p"):
            if not words:
                raise ValueError(f"{word} needs a value.")
            value = words.pop(0)
        elif word[:2] in ("-i", "-p") and len(word) > 2:
            word, value = word[:2], word[2:]
        elif word.startswith("-"):
            raise ValueError(f"Only -i and -p work here, not {word}. Edit .barnaby-home afterwards if you need more.")
        elif target is None:
            target = word
            continue
        else:
            raise ValueError("That's more than user@host. Leave out any remote command.")

        if word == "-i":
            key = value
        elif not value.isdigit():
            raise ValueError(f"{value} isn't a port.")
        else:
            port = value

    if target is None:
        raise ValueError("Which host? Something like ubuntu@203.0.113.10.")
    user, _, host = target.rpartition("@")
    return user or "root", host, port or "", key or ""


def ssh_command(state):
    words = ["ssh"]
    if state.get("SSH_KEY"):
        key = state["SSH_KEY"]
        words += ["-i", "~/" + shlex.quote(key[2:]) if key.startswith("~/") else shlex.quote(key)]
    if state.get("SSH_PORT"):
        words += ["-p", state["SSH_PORT"]]
    return " ".join(words + [shlex.quote(f"{state['SSH_USER']}@{state['SSH_HOST']}")])


def ssh_args(user, host, port="", options=()):
    """An ssh command line, up to the remote command. Options have to come
    before the destination."""
    return ["ssh", "-o", "ConnectTimeout=10", *options] + (["-p", port] if port else []) + [f"{user}@{host}"]


# The public half of each key in the agent, by the path it came from.
ssh_keys_added = {}


def agent_keys():
    result = subprocess.run(["ssh-add", "-L"], capture_output=True, text=True)
    return [" ".join(line.split()[:2]) for line in result.stdout.splitlines()] if result.returncode == 0 else []


def start_ssh(state):
    """Puts the SSH keys in an agent, so passphrases are asked once, and
    points known_hosts at the project."""
    ssh_dir = Path("/root/.ssh")
    ssh_dir.mkdir(mode=0o700, exist_ok=True)
    config = ssh_dir / "config"
    config.write_text(f"Host *\n  UserKnownHostsFile {KNOWN_HOSTS.resolve()}\n  StrictHostKeyChecking accept-new\n")
    config.chmod(0o600)

    if "SSH_AUTH_SOCK" not in os.environ:
        socket = "/tmp/ssh-agent.sock"
        run("ssh-agent", "-a", socket, stdout=subprocess.DEVNULL)
        os.environ["SSH_AUTH_SOCK"] = socket

    # The key that goes on the new system, and the one from the ssh command.
    # ssh refuses keys that look readable by others, which on macOS mounts
    # they can, so it gets copies.
    for name in ("ROOT_KEY", "SSH_KEY"):
        key = expand(state.get(name, ""))
        if not key or key in ssh_keys_added or not Path(key).is_file():
            continue
        copy = Path(tempfile.mkdtemp(), Path(key).name)
        shutil.copyfile(key, copy)
        copy.chmod(0o600)
        before = agent_keys()
        if subprocess.run(["ssh-add", "-q", str(copy)]).returncode == 0:
            added = [line for line in agent_keys() if line not in before]
            ssh_keys_added[key] = added[0] if added else None
        copy.unlink()


def git_add():
    run("git", "add", "-A")


def nix_string(value):
    return json.dumps(value, ensure_ascii=False).replace("${", "\\${")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_secrets():
    secrets = {}
    if SECRETS.exists():
        for line in SECRETS.read_text().splitlines():
            key, sep, value = line.partition("=")
            if sep and not key.startswith("#"):
                secrets[key.strip()] = value
    return secrets


def write_secrets(values):
    """Updates the given keys in secrets.env, and leaves the rest alone."""
    lines = (SECRETS if SECRETS.exists() else TEMPLATE / "secrets.env.example").read_text().splitlines()
    for key, value in values.items():
        line = f"{key}={value}"
        matches = [i for i, existing in enumerate(lines) if existing.partition("=")[0].strip() == key]
        if matches:
            lines[matches[0]] = line
        else:
            lines.append(line)

    fd = os.open(SECRETS, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as file:
        file.write("\n".join(lines) + "\n")
    SECRETS.chmod(0o600)


def substitute(text, old, new):
    if text.count(old) != 1:
        raise Stop(f"The configuration.nix template has changed; can't find {old!r} in it.")
    return text.replace(old, new)


def write_config(state, public_key):
    text = (TEMPLATE / "configuration.nix").read_text()
    for old, new in [
        ('domain = "family.example.com";', f"domain = {nix_string(state['DOMAIN'])};"),
        ('disk = "/dev/sda";', f"disk = {nix_string(state['DISK'])};"),
        ('admins = [ "dad" ];', f"admins = [ {nix_string(state['ADMIN'])} ];"),
        ('name = "Barnaby";', f"name = {nix_string(state['AGENT_NAME'])};"),
        ('time.timeZone = "America/Chicago";', f"time.timeZone = {nix_string(state['TIMEZONE'])};"),
        ('"ssh-ed25519 AAAA... you@laptop"', nix_string(public_key)),
    ]:
        text = substitute(text, old, new)

    if state.get("LOCATION"):
        text = substitute(text, '# location = "41.88,-87.63";', f"location = {nix_string(state['LOCATION'])};")
    for skill in state.get("SKILLS", "").split():
        text = substitute(text, f"# skills.{skill} = true;", f"skills.{skill} = true;")

    CONFIG.write_text(text)
    state["CONFIG_HASH"] = sha256(CONFIG)


def find_disks(state):
    """Lists the VPS's disks over SSH, or returns the error."""
    result = subprocess.run(
        ssh_args(state["SSH_USER"], state["SSH_HOST"], state["SSH_PORT"]) + ["lsblk -dpno NAME,SIZE,TYPE"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None, result.stderr.strip() or f"ssh exited with {result.returncode}."
    disks = [line.split() for line in result.stdout.splitlines()]
    return [(name, size) for name, size, kind in disks if kind == "disk"], None


def configure(_args):
    if not Path("flake.nix").exists():
        raise Stop("Run this in the directory that setup made.")

    state = load_state()
    if (
        CONFIG.exists()
        and CONFIG.read_text() != (TEMPLATE / "configuration.nix").read_text()
        and sha256(CONFIG) != state.get("CONFIG_HASH")
    ):
        if not ask(
            questionary.confirm("configuration.nix has changes configure didn't make. Overwrite them?", default=False)
        ):
            return

    state["DOMAIN"] = ask(
        questionary.text(
            "Domain (the one with DNS pointing at the VPS):",
            default=state.get("DOMAIN", ""),
            validate=lambda d: bool(re.fullmatch(r"[a-z0-9-]+(\.[a-z0-9-]+)+", d.lower())) or "Like family.example.com",
        )
    ).lower()

    # The public half comes from the agent, so a .pub file doesn't have to be
    # next to it.
    state["ROOT_KEY"] = ask(
        questionary.text(
            "The SSH key to log in as root with, once it's installed:",
            default=state.get("ROOT_KEY", "~/.ssh/id_ed25519"),
            validate=lambda k: Path(expand(k)).is_file() or "There's no file there. `ssh-keygen -t ed25519` makes one.",
            instruction="(the private one)",
        )
    )
    start_ssh(state)
    public_key = ssh_keys_added.get(expand(state["ROOT_KEY"]))
    if not public_key:
        raise Stop(f"Couldn't load {state['ROOT_KEY']}.")

    # The disk comes from the VPS itself, which also checks that SSH works.
    # Once it's installed, neither can change.
    command = ssh_command(state) if "SSH_HOST" in state else f"ssh root@{state['DOMAIN']}"
    while not FACTER.exists():
        command = ask(
            questionary.text(
                "How do you SSH into the VPS now?",
                default=command,
                validate=lambda c: _ssh_error(c) or True,
                instruction="(user@host, plus -i and -p if you need them)",
            )
        )
        state["SSH_USER"], state["SSH_HOST"], state["SSH_PORT"], state["SSH_KEY"] = parse_ssh(command)
        start_ssh(state)
        disks, error = find_disks(state)

        if disks:
            names = [name for name, _ in disks]
            state["DISK"] = ask(
                questionary.select(
                    "The disk to install onto. The install erases it.",
                    choices=[questionary.Choice(f"{name} {size}", value=name) for name, size in disks],
                    default=state["DISK"] if state.get("DISK") in names else None,
                )
            )
            break

        print(error or "The VPS doesn't seem to have a disk.", file=sys.stderr)
        choice = ask(questionary.select("Now what?", choices=["Try again", "Type in the disk"]))
        if choice == "Type in the disk":
            state["DISK"] = ask(questionary.text("Disk:", default=state.get("DISK", "/dev/sda")))
            break

    state["ADMIN"] = ask(
        questionary.text(
            "Your username in the chat:",
            default=state.get("ADMIN", os.environ.get("HOST_USER", "").lower()),
            validate=lambda u: bool(LOCALPART.fullmatch(u.lower())) or "Only letters, numbers, and ._=-",
        )
    ).lower()

    state["TIMEZONE"] = ask(
        questionary.text(
            "Time zone:",
            default=state.get("TIMEZONE", os.environ.get("HOST_TZ", "")),
            validate=lambda tz: (".." not in tz and (ZONEINFO / tz).is_file()) or "Like America/Chicago",
        )
    )

    state["AGENT_NAME"] = ask(
        questionary.text(
            "The agent's name:",
            default=state.get("AGENT_NAME", "Barnaby"),
            validate=lambda n: bool(LOCALPART.search(n.lower())) or "It needs at least one letter or number.",
        )
    )

    skills = state.get("SKILLS", "").split()
    state["SKILLS"] = " ".join(
        ask(
            questionary.checkbox(
                "Extra skills (each needs its own key):",
                choices=[
                    questionary.Choice("weather (Tomorrow.io)", value="weather", checked="weather" in skills),
                    questionary.Choice("web-search (Kagi)", value="web-search", checked="web-search" in skills),
                    questionary.Choice("calendar (CalDAV)", value="calendar", checked="calendar" in skills),
                ],
            )
        )
    )

    location, state["LOCATION"] = state.get("LOCATION", ""), ""
    if "weather" in state["SKILLS"].split():
        state["LOCATION"] = ask(
            questionary.text(
                "Home location, as latitude,longitude (for the weather):",
                default=location,
                validate=lambda loc: (
                    bool(re.fullmatch(r"-?\d+(\.\d+)?,-?\d+(\.\d+)?", loc.replace(" ", ""))) or "Like 41.88,-87.63"
                ),
            )
        ).replace(" ", "")

    secrets = read_secrets()
    keys = ["OPENROUTER_API_KEY"] + [key for skill in state["SKILLS"].split() for key in SKILLS[skill]]
    values = {}
    for key in keys:
        current = secrets.get(key, "")
        if key in PLAIN_KEYS:
            values[key] = ask(questionary.text(f"{key}:", default=current, validate=lambda v: bool(v) or "Required"))
        else:
            value = ask(
                questionary.password(
                    f"{key}:",
                    instruction="(Enter keeps the current one)" if current else None,
                    validate=lambda v, current=current: bool(v or current) or "Required",
                )
            )
            values[key] = value or current

    write_secrets(values)
    write_config(state, public_key)
    save_state(state)

    print(
        "\nDone. Your answers are in configuration.nix and secrets.env, and you can edit"
        "\nboth by hand. Next: ./barnaby-home install"
    )


def _ssh_error(command):
    try:
        parse_ssh(command)
    except ValueError as error:
        return str(error)


def setup(args):
    target = Path(args.directory)
    if target.exists() and any(target.iterdir()):
        raise Stop(f"{target} already exists, and isn't empty.")

    shutil.copytree(TEMPLATE, target, copy_function=shutil.copy, dirs_exist_ok=True)
    for path in [target, *target.rglob("*")]:
        path.chmod(path.stat().st_mode | 0o200)

    os.chdir(target)
    run("git", "-c", "init.defaultBranch=main", "init", "-q")
    git_add()
    run("nix", "flake", "lock", "--refresh")

    print(f"\nDone. Next:\n  cd {shlex.quote(args.directory)}\n  ./barnaby-home configure")


def install(_args):
    state = require_state()
    if FACTER.exists():
        raise Stop(
            "It's installed already, so use ./barnaby-home deploy. To erase the VPS"
            " and install again, delete facter.json first."
        )

    target = f"{state['SSH_USER']}@{state['SSH_HOST']}"
    answer = ask(questionary.text(f"This erases {state['DISK']} on {target}. Type {state['DOMAIN']} to go ahead:"))
    if answer.strip().lower() != state["DOMAIN"]:
        raise Stop("Stopped.")

    # A new system means a new host key.
    KNOWN_HOSTS.unlink(missing_ok=True)
    start_ssh(state)
    git_add()

    # nixos-anywhere copies these onto the new system, permissions and all.
    with tempfile.TemporaryDirectory() as extra:
        secrets_dir = Path(extra, "var/lib/barnaby-home")
        secrets_dir.mkdir(parents=True)
        for path in [extra, f"{extra}/var", f"{extra}/var/lib"]:
            os.chmod(path, 0o755)
        secrets_dir.chmod(0o700)
        shutil.copy(SECRETS, secrets_dir / "secrets.env")

        run(
            "nixos-anywhere",
            "--flake",
            ".#home",
            "--build-on",
            "local",
            "--generate-hardware-config",
            "nixos-facter",
            str(FACTER),
            "--extra-files",
            extra,
            "--target-host",
            target,
            *(["--ssh-port", state["SSH_PORT"]] if state.get("SSH_PORT") else []),
        )

    git_add()

    print("\nWaiting for it to come back up...")
    token = wait_for_token(state["SSH_HOST"])
    git_add()
    print(
        f'\nDone. Open https://chat.{state["DOMAIN"]}, choose "Create account", and sign up'
        f"\nas {state['ADMIN']} with this token:\n\n  {token}\n"
        "\nIt keeps working after that, so keep it to yourself. Commit facter.json and known_hosts."
    )


def wait_for_token(host):
    """Reads the registration token once the new system is up, and only then
    trusts its host key. Until the reboot, the installer answers at the same
    address with a different key."""
    for _ in range(60):
        with tempfile.NamedTemporaryFile() as known_hosts:
            result = subprocess.run(
                ssh_args("root", host, options=["-o", f"UserKnownHostsFile={known_hosts.name}"])
                + [f"cat {REMOTE_STATE}/registration-token"],
                capture_output=True,
                text=True,
            )
            if result.returncode == 0 and result.stdout.strip():
                shutil.copyfile(known_hosts.name, KNOWN_HOSTS)
                return result.stdout.strip()
        time.sleep(5)
    raise Stop(f"It didn't come back up. Try: ssh root@{host}")


def deploy(_args):
    state = require_state()
    if not FACTER.exists():
        raise Stop("Install it first: ./barnaby-home install")

    start_ssh(state)
    git_add()

    # The installed system listens on the usual port, whatever the VPS used
    # before.
    ssh = ssh_args("root", state["SSH_HOST"])
    remote = f"{REMOTE_STATE}/secrets.env"
    current = subprocess.run(ssh + [f"sha256sum {remote}"], capture_output=True, text=True).stdout.split()
    secrets_changed = current[:1] != [sha256(SECRETS)]
    if secrets_changed:
        with SECRETS.open("rb") as file:
            run(*ssh, f"umask 077 && cat > {remote}.tmp && mv {remote}.tmp {remote}", stdin=file)

    run(
        "nixos-rebuild",
        "switch",
        "--flake",
        ".#home",
        "--no-reexec",
        "--target-host",
        f"root@{state['SSH_HOST']}",
    )

    if secrets_changed:
        print("secrets.env changed, so restarting the agent.")
        run(*ssh, "systemctl restart container@barnaby")


def update(args):
    run("nix", "flake", "update", "--refresh")
    deploy(args)


def fix_ownership(path, like):
    """Gives files made in the container to whoever owns the project."""
    owner = os.stat(like)
    for root, dirs, files in os.walk(path):
        for name in [root, *(os.path.join(root, n) for n in dirs + files)]:
            try:
                os.lchown(name, owner.st_uid, owner.st_gid)
            except OSError:
                pass


def main():
    parser = argparse.ArgumentParser(prog="barnaby-home", description="Set up and run a Barnaby Home server.")
    commands = parser.add_subparsers(required=True, metavar="command")
    setup_parser = commands.add_parser("setup", help="Make a new project directory")
    setup_parser.add_argument("directory")
    setup_parser.set_defaults(command=setup)
    for name, command, summary in [
        ("configure", configure, "Answer a few questions to write the config"),
        ("install", install, "Install onto the VPS, erasing it"),
        ("deploy", deploy, "Apply changes to the config or secrets.env"),
        ("update", update, "Update Barnaby Home and everything else, then deploy"),
    ]:
        commands.add_parser(name, help=summary).set_defaults(command=command)
    args = parser.parse_args()

    # The project belongs to someone else as far as the container's root is
    # concerned, and git won't touch it otherwise.
    os.environ.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="safe.directory", GIT_CONFIG_VALUE_0="*")

    project = os.getcwd()
    try:
        args.command(args)
    except Stop as stop:
        sys.exit(str(stop))
    except subprocess.CalledProcessError as error:
        sys.exit(error.returncode)
    except KeyboardInterrupt:
        sys.exit(130)
    finally:
        fix_ownership(project if args.command != setup else os.path.join(project, args.directory), project)


if __name__ == "__main__":
    main()
