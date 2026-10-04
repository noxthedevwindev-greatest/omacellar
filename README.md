# omacellar

A cellar of Windows runners. Install, update and juggle Wine and Proton builds
from one command line tool, and keep the installations that run on them.

No daemon, no GUI, no database. A shell script, a directory of runners, and a
directory of prefixes. Built for Omarchy, but nothing in it is Omarchy
specific — it runs on any Linux with `bash`, `curl`, `jq`, `tar` and `xz`.

```
$ omacellar runner list
installed
    NAME                      ID         VERSION  KIND    SIZE    RUNNER SAYS  STEAM
ok  soda-11.0-10             soda       11.0-10  wine    662 MiB wine-11.0    n/a
ok  protosoda-11.0-3         protosoda  11.0-3   proton  1.4 GiB wine-11.0    yes

available upstream
ID               TITLE       LATEST   KIND    CHANNEL  INSTALLED
soda             Soda        11.0-10  wine    stable   11.0-10
protosoda        ProtoSoda   11.0-3   proton  stable   11.0-3
proton-ge        GE-Proton   7        proton  stable   -
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/noxthedevwindev-greatest/omacellar/main/install.sh | sudo bash
```

That installs the binary to `/usr/bin`, its libraries to `/usr/share/omacellar`,
and completions for bash, zsh and fish. Nothing is written to your home
directory; the cellar appears at `~/.omacellar` the first time you run a
command.

<details>
<summary>From a checkout</summary>

```bash
git clone https://github.com/noxthedevwindev-greatest/omacellar
cd omacellar
sudo ./install.sh
```

Or skip installing entirely and run `./bin/omacellar` in place.

</details>

<details>
<summary>Uninstall</summary>

```bash
sudo ./uninstall.sh              # remove the program, ask about your cellar
sudo ./uninstall.sh --keep-data  # remove the program, keep ~/.omacellar
sudo ./uninstall.sh --purge      # remove the program and ~/.omacellar
```

It removes the binary, its libraries, the completions and the docs, then asks
what to do with `~/.omacellar`. That directory is several gigabytes of runners
and prefixes, so it is never deleted without you saying so: `--keep-data`
skips the question and keeps it, `--purge` skips the question and deletes it.

Running it without `sudo` is fine if you installed to a `PREFIX` you own. It
reports what it could not remove and tells you to re-run with `sudo`.

</details>

Arch users: an `omarchy/PKGBUILD` is in the repo and is shaped for submission
to `pkgs.omarchy.org`.

## Quick start

```bash
omacellar runner add soda                  # download, verify, unpack
omacellar prefix create games              # make an installation
omacellar prefix run games game.exe        # use it
omacellar runner update --all              # keep up with upstream
```

`prefix create` boots the prefix once so it is usable straight away.

## Why another Wine manager

Choosing a Wine build in 2026 means sorting through upstream Wine,
wine-staging, Wine-GE, GE-Proton, tkg, and then the Bottles family: Soda,
Caffe, Vaniglia, McSoda, ProtoSoda. Each has its own download page, its own
version numbers, and its own opinion about how a prefix should be built.

Bottles puts a GUI on that. omacellar puts one interface on it and stays out of
the way:

```bash
omacellar runner list             # what's installed, what upstream offers
omacellar runner info soda        # everything known about one runner
omacellar runner old              # versions kept from previous updates
omacellar doctor                  # is anything wrong with this machine
```

### Runners it knows

| id | what it is | kind |
|---|---|---|
| `soda` | Bottles' Wine fork: Wayland native, GStreamer, real win32 prefixes | wine |
| `soda-dev` | Soda experimental builds | wine |
| `caffe` | Caffeine-flavoured TkG/staging build, WoW64 | wine |
| `vaniglia` | Bottles' clean upstream-ish build | wine |
| `mcsoda` | Soda plus extra compatibility work | wine |
| `protosoda` | Proton environment (umu/ProtonFixes) on top of Soda | proton |
| `wine-ge` | GloriousEggroll's Wine | wine |
| `wine-ge-lol` | Wine GE tuned for League of Legends | wine |
| `proton-ge` | GloriousEggroll's Proton, the safe choice for Steam games | proton |
| `kron4ek` | Kron4ek's builds straight from the WineHQ tree | wine |
| `kron4ek-staging` | the same with wine-staging patches | wine |
| `kron4ek-tkg` | turn-key Gentoo builds, heavily patched | wine |

Nothing is hard coded. Assets are matched by pattern against each publisher's
GitHub releases, so when upstream renames something you get "no matching asset"
and a homepage to look at, rather than a silent 404.

To add your own, drop a line into `~/.omacellar/data/runner_types/runners.conf`.
The format is one pipe-separated record per runner, documented in the header of
the file itself.

## Where things live

Everything is under `~/.omacellar`, in one place, so a cache cleaner that only
knows about `~/.cache` and `~/.local/share` cannot wipe a cellar or your
settings.

```
~/.omacellar/
  config.json                   settings
  runners/
    soda/New/11.0-10/           the active version
    soda/Old/11.0-4/            the version it replaced, still launchable
    soda-9.9 -> /elsewhere      a linked runner
  prefixes/<name>/              installations
  data/
    runner_types/runners.conf   the editable catalogue
    version_lists/              cached version listings
    logs/                       session logs
    cache/                      tarballs and GitHub responses
```

Two ideas are worth knowing up front.

**One active version per runner.** Updating installs the new version under
`New/` and moves the outgoing one to `Old/`, where it keeps working. A prefix
built against the old version is not stranded. `runner old` lists what is kept
and `runner activate soda@11.0-4` swaps back. Set `keep_versions=false` (the
default) and the replaced version is deleted afterwards instead.

**Runners carry their own identity.** Every unpacked runner gets a
`.omacellar-version` file inside it recording its id, version, tag and reported
version. Rename the directory, move the cellar, adopt somebody else's build —
omacellar reads that file before it trusts a path, so a runner still knows what
it is.

## How it treats your data

**It verifies what it downloads.** Every asset is checked against the SHA-256
GitHub publishes for it before anything is unpacked.

**It never leaves a broken runner behind.** Downloads unpack into a staging
directory and move into place with one rename. An interrupted install leaves a
`.staging-*` directory that the next run cleans up.

**It asks before it changes something.** See below.

**Nothing runs in a polluted environment.** `WINEPREFIX`, `WINE`, `WINELOADER`,
`WINESERVER`, `WINEDLLPATH`, `WINEARCH` and the `STEAM_COMPAT_*` variables are
cleared before every launch, so a prefix cannot pick up another runner's
settings by accident.

**It knows which runners can make which prefixes.** Soda and the Kron4ek builds
ship 32-bit libraries and can make a pure `win32` prefix. Caffe is a WoW64
build and refuses `WINEARCH=win32`. omacellar detects which kind a runner is and
tells you what will actually happen rather than letting `wineboot` fail.

**Proton runners know they are Proton.** They get built by Proton itself
(`proton runinprefix wineboot -u`), keep their prefix in `<prefix>/pfx`, launch
with `runinprefix` instead of the Steam-only `run`, and are registered in
Steam's `compatibilitytools.d` so they appear as a compatibility choice.

**Existing collections count.** If you already have runners on disk, point
`runners_dir` at them and run `runner adopt`. Nothing is copied and nothing is
downloaded; each directory just gains a small `.omacellar.json` describing what
it is, and you gain update checking and installation management.

## It asks before it changes things

**On boot.** `prefix create` checks whether the runner it is about to use has a
newer build and asks first:

```
==> update for a runner
New version detected for the runner below.
Do you want to update to the latest runner?
 .Soda (old 11.0-4 / 11.0-10)
>(y/n)
```

`--yes` takes the update without asking. With no terminal and no `--yes`, the
installed version is used as-is and nothing is downloaded.

**On a bad checksum.** The default answer is no:

```
SHA verification failed
SHA verification for the runner below FAILED.
These types of runners can be a threat to your system.
 .Soda (11.0-10)
expected sha256:1a2b...
actual   sha256:9f8e...
>(y/n)
```

`--insecure` overrides for unattended installs. Without a terminal and without
`--insecure`, it refuses rather than guessing.

**On a broken prefix.** `prefix run` inspects the prefix first. Problems it
knows how to repair are listed with an offer to repair them; anything else is
reported plainly and left alone rather than guessed at.

```
Problems found
 . the runner this prefix was built with is gone
omacellar knows how to fix this. Press Y to fix, N to exit.
>(y/n)
```

`--no-fix` skips the check.

## Commands

```
runner list                 installed runners and what upstream offers
runner search <text>        find runners by name or description
runner info <name>          everything known about one runner
runner available <id>       every published version of a runner
runner add <id>[@version]   download and install a runner
runner remove <name>        uninstall a runner
runner update [name|--all]  fetch newer builds
runner link <path>          adopt a runner directory already on disk
runner unlink <name>        forget a linked runner
runner adopt                register untracked runner directories
runner path <name>          print where a runner lives
runner old                  versions kept in Old/
runner activate <id>[@ver]  make a kept version the active one
runner steam <name>         register a Proton runner with Steam
runner unsteam <name>       undo that
runner exec <name> <cmd>    run a command inside a runner

prefix list                     list installations
prefix create <name>            new installation
prefix remove <name>            delete an installation
prefix info <name>              what is inside an installation
prefix path <name>              print an installation path
prefix run <name> <program>     run a program in an installation
prefix shell <name> [terminal]  a terminal with the environment ready
prefix winetricks <name> [verb] run winetricks against an installation
prefix env <name>               shell exports, for eval

status              one screen summary
about               who made this
doctor              check the machine for problems
migrate             adopt a cellar from an older layout
config <get|set>    read and write configuration
completions <shell> bash, zsh or fish
```

`runners` and `p` work as aliases where you would expect them.
`help runner` and `help prefix` print the long form.

## Scripting

Every listing command takes `--json` and prints one object instead of a table:

```bash
omacellar runner list --installed --json | jq -r '.installed[].name'
omacellar status --json | jq '.updates'
omacellar prefix list --json | jq -r '.prefixes[] | select(.valid) | .name'
```

Available on `runner list`, `runner info`, `runner old`, `prefix list` and
`status`. Tables stay the default, so `omacellar runner list > notes.txt` still
looks like a table.

Sizes are reported in bytes as `size_bytes`, and paths are absolute, so nothing
has to be guessed at.

## Configuration

`~/.omacellar/config.json`, or `omacellar config list`.

| key | meaning |
|---|---|
| `default_runner` | runner used when a prefix does not name one |
| `runners_dir` | where runners live, point at an existing collection to adopt it |
| `prefix_dir` | where installations live |
| `channel` | `stable`, `experimental` or `all`, filters discovery |
| `keep_versions` | keep the replaced version in `Old/` |
| `api_cache_ttl` | seconds to cache GitHub responses, `0` disables caching |
| `steam_compat_tools` | register Proton runners with Steam on install |
| `runner_env` | extra `VAR=VALUE` lines applied to every launch |
| `ascii_art` | draw the logo in `omacellar about` |
| `log_level` | verbosity for session logs |

Environment overrides: `OMACELLAR_HOME`, `OMACELLAR_ROOT`, `GITHUB_TOKEN`,
`STEAM_COMPAT_TOOLS_ROOT`, `NO_COLOR`, `OMACELLAR_ASSUME_YES`.

An older `~/.config/omacellar/config` is imported into `config.json` the first
time omacellar runs, and the old file is left where it is. An older cellar at
`~/.local/share/omacellar` is picked up by `omacellar migrate`, which moves
runners into the `New/`/`Old/` shape and re-points the absolute prefix path each
prefix recorded.

Unauthenticated GitHub API calls are limited to 60 per hour. Set `GITHUB_TOKEN`
if you plan on polling a lot.

## Development

```bash
test/smoke.sh                              # fast, no runner needed
test/smoke.sh ~/runners/*                  # also link real runners
OMACELLAR_SMOKE_FULL=1 test/smoke.sh ...   # create a prefix and launch cmd.exe
```

The suite runs against a throwaway cellar and a fake registry with real
tarballs, so install, update, activate and migrate are all covered without the
network touching your machine. Unauthenticated GitHub allows 60 calls an hour
and the suite spends about a dozen, so seed a cache when running it repeatedly:

```bash
test/smoke.sh --api-cache ~/.omacellar/data/cache/api
```

It checks the remaining quota up front and skips the network-backed cases when
it is gone, rather than reporting failures that have nothing to do with the
code.

Full mode takes a few minutes because it boots a real prefix and runs
`cmd.exe` in it.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).