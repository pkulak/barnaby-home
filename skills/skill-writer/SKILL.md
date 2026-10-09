---
name: skill-writer
description: Create, change, or remove your own skills, and store API keys they need. Use when someone asks you to learn a new trick, remember how to do a task, or change or remove a skill you wrote.
---

# Writing your own skills

You can write your own skills. Everything else about you (your soul, model, and
settings, and the bundled skills) is set by the family's admin and is read-only.

## Where they go

Your skills live in `~/.agents/skills/<name>/SKILL.md`. That folder is a git
repo. If it doesn't exist yet, set it up first:

```bash
mkdir -p ~/.agents/skills && cd ~/.agents/skills && git init -q
git config user.name "<your name>"
git config user.email "$(echo "${BARNABY_MATRIX_USER_ID#@}" | tr : @)"
```

A skill is a folder with a `SKILL.md`, plus any scripts it needs:

```markdown
---
name: homework-planner
description: Plan homework for the week from a list of assignments. Use when someone shares assignments or asks what's due.
---

# Homework planner

Instructions for yourself, in plain language. Run scripts relative to this
folder, like `scripts/plan.py`.
```

- The name uses lowercase letters, numbers, and hyphens, and matches the folder.
- The description says what the skill does and when to use it. It's all you'll
  see of the skill until you load it, so make it specific.
- Never reuse the name of a skill you already have from the admin (check
  `ls ~/skills`). Those can't be changed; write a separately named skill
  instead, or tell the person to ask the admin.
- Test scripts before you commit them.

## Tools

Most common command-line tools are installed, along with Python (with requests,
lxml, pyyaml, pillow, dateutil, pandas, pypdf, and caldav) and Node. For
anything else, use `nix shell nixpkgs#<package> -c <command>` in your scripts.

## Saving a change

Commit every change, with a short message saying what changed and who asked:

```bash
cd ~/.agents/skills && git add -A && git commit -q -m "Add homework-planner, for Sam."
```

Removing a skill is the same: `git rm -r <name>`, then commit.

## Using a new skill

Skills are only listed when you start, so a new one won't appear in your list
yet. Read its `SKILL.md` and use it right away. If you set a reminder that needs
it, include the path to its `SKILL.md` in the reminder.

## Announcing it

Every time you add, change, or remove a skill, post one short line to the Family
room saying who asked and the skill's name, without its contents. For example:
"Sam taught me a new skill: homework-planner."

If the request came from the Family room, just say it in your reply. If it came
from a DM, react ✅ to the request, and make your whole reply the announcement,
starting with `<send-to>ROOM_ID</send-to>`. Get the room ID with
`echo $BARNABY_MATRIX_ROOM_ID`. The whole reply goes to the Family room.

## API keys

If a skill needs an API key, ask the person to send it to you in a DM, not in
the Family room. Save it to `~/.agents/secrets.env`, which is outside the git
repo so a commit can never include it:

```bash
umask 077 && echo 'WIDGET_API_KEY=...' >> ~/.agents/secrets.env
```

Scripts load it with `set -a; . ~/.agents/secrets.env; set +a` (or by reading
the file in Python). Never put a key in a skill's files or in a commit, and
never repeat one in a reply.

Once the skill works, suggest that the person deletes the message with the key.
