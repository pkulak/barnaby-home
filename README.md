# Barnaby Home

Barnaby Home turns a fresh VPS into a private chat server for a family, with a
[Barnaby](https://github.com/pkulak/barnaby) agent living in the family room.
A script asks you for a domain, an SSH key, and an OpenRouter key, then
installs the rest. All it needs on your computer is Docker.

What you get:

| Address | What's there |
|---|---|
| `https://chat.<domain>` | [Element](https://element.io), the chat app, in the browser |
| `<domain>` | The Matrix server, [tuwunel](https://github.com/matrix-construct/tuwunel), including its sign-up and sign-in pages |
| `call.<domain>` | Voice and video calls, through [LiveKit](https://livekit.io) |

Everyone who signs up lands in an encrypted Family room with the agent. The room
is closed to other Matrix servers, and sign-up needs a token, so nobody gets in
without an invite.

The agent talks to models through [OpenRouter](https://openrouter.ai), and the
defaults all have zero data retention (ZDR) endpoints: providers that don't store
or train on your messages.

## Requirements

- **A VPS** with at least 2 GB of RAM (nixos-anywhere needs 1.5 GB just to
  install) and 20 GB of disk, running any x86_64 Linux you can SSH into as root
  or as a user with sudo. The install erases it. So far it's only been tested on
  an AWS EC2 t3.small. Everything runs in about 450 MB, and builds happen on
  your computer, so you can probably shrink it to 1 GB after the install.
- **A domain**, or a subdomain of one you already have.
- **[Docker](https://docs.docker.com/get-docker/)** on your own computer, and
  10 GB or so of disk for it. On a Mac with Apple Silicon, it runs the x86_64
  container through Rosetta (Docker Desktop's "Use Rosetta" setting), which
  is slower.
- **An SSH key.** If you don't have one, `ssh-keygen -t ed25519` makes one.
- **An OpenRouter API key.** Turn on "Zero Data Retention" in OpenRouter's privacy
  settings too; it's the only thing that stops a request from going to a
  provider that keeps it (see [Privacy](#privacy)).

## Installing

### 1. Point DNS at the VPS

Add two `A` records (and `AAAA`, if the VPS has IPv6), both pointing at the VPS:

```
family.example.com      A  203.0.113.10
*.family.example.com    A  203.0.113.10
```

The wildcard covers `chat.` and `call.`. Let's Encrypt checks these names during
the install, so set them up first, and give the VPS a static IP (an Elastic IP,
on AWS) so they stay right.

### 2. Open the ports

NixOS runs its own firewall, but most providers also have one in front of the
VPS (a security group, on AWS). Open these there:

| Port | Protocol | For |
|---|---|---|
| 22 | TCP | SSH |
| 80, 443 | TCP | The web, Matrix, and certificates |
| 7881 | TCP | Calls, when UDP is blocked |
| 50000–51000 | UDP | Calls |
| 3478 | UDP | Calls through TURN, for people behind strict NAT |
| 5349 | TCP | Calls through TURN over TLS, for networks that block UDP |

Leave out everything but 22, 80, and 443 if you set `calls.enable = false`.

### 3. Set up

```bash
curl -fsSLO https://raw.githubusercontent.com/pkulak/barnaby-home/main/template/barnaby-home
bash barnaby-home setup family
cd family
```

That makes a `family` directory with a git repository, the config, and a copy
of the script. Everything after this runs from there. The first run takes a few
minutes, while Docker downloads Nix and Nix downloads everything else.

### 4. Configure

```bash
./barnaby-home configure
```

It asks for the domain, the SSH key to log in with (`~/.ssh/id_ed25519`, by
default), how you SSH into the VPS now (`ssh -i ~/keys/aws.pem
ubuntu@203.0.113.10`, say), your username in the chat, the time zone, the
agent's name, any extra skills, and the OpenRouter key. It logs in to the VPS to find the disk to install onto.

The answers go into `configuration.nix` and `secrets.env` (which git ignores,
so the keys never end up in the repository or the Nix store), and you can edit
both by hand from here on; see [Configuration](#configuration). You can run
configure again, too, but it starts `configuration.nix` over, so it asks first
if you've changed anything.

The agent works fine without knowing anything about your family, but it's much
better when it does. Edit `soul.md` (who's who, where you live, which teams you
follow) and uncomment `soul = ./soul.md;` in `configuration.nix`. You can do
this later, too; it takes effect on the next deploy.

### 5. Install

```bash
./barnaby-home install
```

This erases the VPS, so it has you type the domain first. Then it runs
nixos-anywhere, which builds the system on your computer, copies it over, and
reboots the VPS into NixOS. It writes two files you should commit:
`facter.json`, which describes the VPS's hardware, and `known_hosts`, its new
SSH host key.

### 6. Sign up

At the end, install prints the setup token. Open `https://chat.family.example.com`,
choose "Create account", and sign up with your username and that token. Within a
minute you're a server admin, and an admin room shows up in Element (under
"System Alerts"). You'll also be in the Family room with the agent.

If you lose the token, it's on the server:

```bash
ssh root@family.example.com cat /var/lib/barnaby-home/registration-token
```

### 7. Invite your family

Make a one-time invite token by sending this in the admin room:

```
!admin token issue --once --max-age 7d
```

Send them the token and the `https://chat.<domain>` link. Once they sign up,
they're in the Family room too.

The setup token keeps working, so keep it to yourself.

## Updating

After changing `configuration.nix`, `soul.md`, or `secrets.env`:

```bash
./barnaby-home deploy
```

It builds on your computer, switches the server over, and if `secrets.env`
changed, copies it up and restarts the agent. That replaces the server's copy,
so make key changes here, not there. If a key that a skill needs is missing,
`journalctl -u barnaby-home-setup` on the server says so.

To update Barnaby Home, Barnaby, and NixOS, then deploy:

```bash
./barnaby-home update
```

Docker keeps the Nix store in a volume, so these don't download everything
again. It only grows; `docker volume rm barnaby-home-nix` gets the space back,
and the next run starts over.

## Configuration

Everything is under `barnabyHome` in `configuration.nix`:

| Option | Default | What it does |
|---|---|---|
| `domain` | | The Matrix server name, and the base for `chat.` and `call.` |
| `disk` | | The disk to install onto |
| `admins` | `[ ]` | Usernames that become server admins when they sign up |
| `location` | `null` | `"latitude,longitude"`, the weather skill's default location |
| `secretsFile` | `/var/lib/barnaby-home/secrets.env` | Where the keys are. Point this at an agenix or sops secret if you use those. |
| `calls.enable` | `true` | Voice and video calls |
| `agent.name` | `"Barnaby"` | The agent's display name |
| `agent.username` | `name`, lowercased | Its Matrix username. It's set on first boot, so changing it later does nothing. |
| `agent.soul` | Barnaby's, with `name` filled in | A file with the agent's personality and instructions, where `@name@` becomes `name` |
| `agent.model` | `deepseek/deepseek-v4.1-flash` | The OpenRouter model it chats with |
| `agent.skills` | See below | Skills to turn on or off |

The agent also uses the system's `time.timeZone`.

## Skills

| Skill | What it does | Needs | Default |
|---|---|---|---|
| `image` | Draws and edits images | `OPENROUTER_API_KEY` | On |
| `transcribe` | Reads voice messages | `OPENROUTER_API_KEY` | On |
| `sports-scores` | Scores, schedules, and standings | `OPENROUTER_API_KEY` | On |
| `sports-monitor` | Watches a game and sends one alert | Nothing more | On |
| `weather` | Forecasts and conditions | `TOMORROWIO_API_KEY` | Off |
| `web-search` | Searches the web with Kagi | `KAGI_KEY` | Off |
| `calendar` | Reads and edits a CalDAV calendar | `CALDAV_URL`, `CALDAV_USERNAME`, `CALDAV_PASSWORD` | Off |
| `skill-writer` | Lets the agent write its own skills | Nothing more | On |

Turn one on with `agent.skills.weather = true;`, or off with `false`. Turning
off `sports-scores` turns off `sports-monitor` too. A path to a
directory with a `SKILL.md` adds your own; see Barnaby's
[skills docs](https://github.com/pkulak/barnaby/blob/master/docs/skills.md).

### The agent's own skills

With `skill-writer` on, anyone can ask the agent to learn something new ("every
Sunday, check what's due this week"), and it writes itself a skill. It can't
change the bundled skills, its soul, or anything else in your config.

- Its skills live in `/var/lib/barnaby/.agents/skills`, a git repo, and it
  commits every change. To see what it's done, or undo something, SSH in and
  use `git log` and `git revert` there.
- Whenever it adds, changes, or removes a skill, it says so in the Family room,
  even if someone asked in a DM.
- If a skill needs an API key, it asks for it in a DM, saves it to
  `/var/lib/barnaby/.agents/secrets.env`, and suggests deleting the message.
- It has the usual command-line tools (git, ripgrep, jq, ffmpeg, ImageMagick,
  pandoc, Python, Node, and more), and can `nix shell` anything else. Weekly
  garbage collection cleans those up again.

## Privacy

The chat server is yours: messages, accounts, and files stay on the VPS. The
agent, of course, has to send what it reads to a model. Here's where it goes:

- **Chat:** `agent.model`, through OpenRouter. The default, DeepSeek V4.1 Flash,
  is an open model with ZDR endpoints at over 20 providers.
- **Every Family room message:** [Jev](https://openrouter.ai/typesafe/jev-1.13),
  a tiny ZDR model that decides whether it's meant for the agent. The agent
  still gets every message as context, but only the ones meant for it start a
  turn (and a call to `agent.model`).
- **Memory:** every night, `agent.model` also reads conversations that have
  been quiet for 3 days and writes them up as notes, which the agent can search
  later. The notes stay on the VPS, in `/var/lib/barnaby/memory`.
- **Images and voice messages:** Microsoft's MAI models on Azure, through
  OpenRouter, both ZDR.
- **Weather, search, and calendar:** Tomorrow.io, Kagi, and your CalDAV server,
  but only if you turn them on.
- **The agent's own skills:** whatever services they use.

The agent has one conversation across every room and DM, so it knows what was
said in DMs when it's talking in the Family room. It's told not to repeat
private things from DMs, but that's an instruction, not a wall. The same goes
for API keys: one sent in a DM is still in the agent's context, and in its
session files on the VPS, even after the message is deleted.

Nothing in Barnaby Home forces OpenRouter to use ZDR endpoints yet. OpenRouter's
account setting does: with it on, a request to a model without a ZDR endpoint
fails instead of quietly going somewhere else.

## Limitations

- **No backups yet.** Everything lives in `/var/lib`, including the agent's
  own skills and keys, and losing the VPS loses it.
- **The agent created the Family room, so it's the room's admin.** Nothing
  hands that to a person yet.
- **Phone apps haven't been tested yet.** Element in the browser works,
  including calls.

## Installing without the script

If you already have Nix, with flakes, you can skip Docker. The script runs these
same commands.

```bash
mkdir family && cd family
nix flake init -t github:pkulak/barnaby-home
git init && git add .
cp secrets.env.example secrets.env && chmod 600 secrets.env
```

Edit `configuration.nix` (at least the domain, disk, admin, time zone, and SSH
key) and `secrets.env`. Then put `secrets.env` where the server expects it, and
install:

```bash
mkdir -p extra/var/lib/barnaby-home
chmod 755 extra extra/var extra/var/lib
chmod 700 extra/var/lib/barnaby-home
cp secrets.env extra/var/lib/barnaby-home/

nix run github:nix-community/nixos-anywhere -- \
  --flake .#home \
  --generate-hardware-config nixos-facter ./facter.json \
  --extra-files ./extra \
  --target-host root@203.0.113.10

rm -r extra
git add facter.json
```

To deploy changes (add `--build-host root@family.example.com` on a Mac):

```bash
nix run nixpkgs#nixos-rebuild -- switch --flake .#home --target-host root@family.example.com
```

Keys live on the server after that, in `/var/lib/barnaby-home/secrets.env`;
restart the agent with `systemctl restart container@barnaby` after changing
them.
