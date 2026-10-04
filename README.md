# omacellar

**A cellar of Windows runners.** One command line tool to install, update and
swap Wine and Proton builds, and to keep the installations that run on them.

Bottles does this with a GUI. omacellar does it with a terminal, a config file
and no daemon. It was built for Omarchy, but nothing in it is Omarchy specific.

```
$ omacellar runner list
installed

    NAME                      ID         VERSION    KIND    SIZE    RUNNER SAYS    STEAM
ok  soda-11.0-10              soda       11.0-10    wine    662 MiB wine-11.0       n/a
ok  protosoda-11.0-3          protosoda  11.0-3     proton  1.4 GiB wine-11.0       yes

available upstream
ID               TITLE       LATEST   KIND    CHANNEL  INSTALLED
soda             Soda        11.0-10  wine    stable   11.0-10
protosoda        ProtoSoda   11.0-3   proton  stable   11.0-3
proton-ge        GE-Proton   7        proton  stable   -
```

## Why

Picking a Wine build in 2026 is a mess. There is upstream Wine, wine-staging,
Wine-GE, GE-Proton, tkg, and then the Bottles family: Soda, Caffe, Vaniglia,
McSoda, ProtoSoda. Every one of them has its own download page, its own
versioning scheme, and its own idea of how a prefix should be created.

omacellar puts all of them behind one interface:

```bash
omacellar runner add soda           # download, verify, unpack
omacellar prefix create games       # make an installation
omacellar prefix run games game.exe # use it
omacellar runner update --all       # keep up with upstream
```

## Runners it knows

| id | what it is | kind |
|---|---|---|
| `soda` | Bottles' Wine fork: Wayland native, GStreamer, real win32 prefixes | wine |
| `soda-dev` | Soda experimental builds | wine |
| `caffe` | TkG/staging/esync build, WoW64 | wine |
| `vaniglia` | Bottles' clean upstream-ish build | wine |
| `mcsoda` | Soda plus extra compatibility work | wine |
| `protosoda` | Proton environment on top of Soda, for UMU and games | proton |
| `wine-ge` | GloriousEggroll's Wine | wine |
| `wine-ge-lol` | Wine GE tuned for League of Legends | wine |
| `proton-ge` | GloriousEggroll's Proton | proton |
| `kron4ek` | Kron4ek's plain Wine builds | wine |
| `kron4ek-staging` | the same with wine-staging patches | wine |
| `kron4ek-tkg` | turn-key Gentoo builds, heavily patched | wine |

Add your own by dropping a line into `registry/runners.conf`. Nothing is
hard coded: assets are matched by pattern against each publisher's GitHub
releases, so a rename upstream shows up as "no matching asset" instead of a
silent 404.

## Install

### curl

```bash
curl -fsSL https://raw.githubusercontent.com/noxthedevwindev-greatest/omacellar/main/install.sh | sudo bash
```

That drops `omacellar` in `/usr/bin`, its libraries in
`/usr/share/omacellar`, and the completions for bash, zsh and fish where your
shell will find them. Requires `bash`, `curl`, `jq`, `tar` and `xz`.

Nothing is written to your home directory at install time. The cellar at
`~/.omacellar` is created the first time you run a command.

### From a checkout

```bash
git clone https://github.com/noxthedevwindev-greatest/omacellar
sudo install -Dm755 omacellar/bin/omacellar /usr/bin/omacellar
sudo install -d /usr/share/omacellar/lib /usr/share/omacellar/registry
sudo install -m644 omacellar/lib/*.sh /usr/share/omacellar/lib/
sudo install -m644 omacellar/registry/runners.conf /usr/share/omacellar/registry/
```

Or just run it in place, `./bin/omacellar`.

## Where it keeps things

Everything lives in one hidden directory, `~/.omacellar`, so a cache cleaner
that only knows about `~/.cache` and `~/.local/share` cannot wipe a cellar or
its settings.

```
~/.omacellar/
  config.json                  settings, written by `omacellar config`
  runners/
    soda/New/11.0-10/          the version that is active
    soda/Old/11.0-4/           the version it replaced, still launchable
    soda-9.9 -> /elsewhere     a linked runner, one directory per name
  prefixes/<name>/             installations
  data/
    runner_types/runners.conf  the editable catalogue of known runners
    version_lists/             cached version listings
    logs/                      session logs
    cache/downloads/           tarballs, kept for reuse
    cache/api/                 GitHub responses
```

Exactly one version of each runner is ever active, under `New/`. Updating
installs the new version there and moves the outgoing one to `Old/` where it
keeps working. `keep_versions=false` (the default) deletes the old copy
afterwards instead.

Every unpacked runner gets a `.omacellar-version` file inside it recording its
id, version, tag and reported version, so a runner still identifies itself
after its directory has been renamed or moved. omacellar reads that before it
trusts a directory name.

`~/.local/share/omacellar` from older versions is picked up by
`omacellar migrate`, which moves runners into the `New/`/`Old/` shape and
re-points the `prefix_dir` each prefix recorded.

Packaging lives in `omarchy/`. Dependencies are `bash`, `curl`, `jq`, `tar` and
`xz`. `winetricks` and `vulkan-tools` are optional.

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
runner steam <name>         register a Proton runner with Steam
runner unsteam <name>       undo that
runner exec <name> <cmd>    run a command inside a runner
runner old                  versions kept in Old/
runner activate <id>[@ver]  make a kept version the active one

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
migrate             adopt a cellar from an older ~/.local/share/omacellar
config <get|set>    read and write configuration
completions <shell> bash, zsh or fish
```

`runners` and `p` work as aliases where you would expect them.

## Scripting it

Every listing command takes `--json` and prints one object instead of a table:

```bash
omacellar runner list --installed --json | jq -r '.installed[].name'
omacellar status --json | jq '.updates'
omacellar prefix list --json | jq -r '.prefixes[] | select(.valid) | .name'
```

Available on `runner list`, `runner info`, `runner old`, `prefix list` and
`status`. Tables stay the default, so piping to a file still looks right.

## Asking before it changes things

**On boot.** `prefix create` checks whether the runner it is about to use has a
newer build, and asks before updating:

```
==> update for a runner
New version detected for the runner below.
Do you want to update to the latest runner?
 .Soda (old 11.0-4 / 11.0-10)
>(y/n)
```

`--yes` takes the update without asking. With no terminal and no `--yes`, the
installed version is used as-is and nothing is downloaded.

**Bad checksums.** A SHA mismatch shows what was expected and what arrived, and
asks. The default answer is no:

```
SHA verification failed
SHA verification for the runner below FAILED.
These types of runners can be a threat to your system.
 .Soda (11.0-10)
expected sha256:1a2b...
actual   sha256:9f8e...
>(y/n)
```

`--insecure` accepts a bad checksum without being asked, for unattended use.

**Broken prefixes.** `prefix run` inspects the prefix first. Problems it knows
how to repair are listed with an offer to repair them; anything else is
reported and left alone rather than guessed at.

```
Problems found
 . the runner this prefix was built with is gone
omacellar knows how to fix this. Press Y to fix, N to exit.
>(y/n)
```

`--no-fix` skips the check.

## Things it gets right

**Verified downloads.** Every asset is checked against the SHA-256 GitHub
publishes for it before anything is unpacked. A mismatch stops and leaves the
previous version alone, unless you explicitly say otherwise.

**Updates never leave you stranded.** The version being replaced moves to
`Old/` rather than being deleted, so a bottle that was built against it keeps
running. `runner activate` swaps back.

**Nothing half installed.** Runners unpack into a staging directory and are
moved into place with one rename. An interrupted download leaves a `.staging-*`
directory that the next run cleans up, never a broken runner in the cellar.

**No environment bleed.** `WINEPREFIX`, `WINE`, `WINELOADER`, `WINESERVER`,
`WINEDLLPATH`, `WINEARCH` and the `STEAM_COMPAT_*` variables are cleared before
every launch, so a prefix never picks up another runner's settings by accident.

**WoW64 versus multilib, handled.** Soda and the Kron4ek builds ship 32-bit
libraries and can make a pure `win32` prefix. Caffe is a WoW64 build and refuses
`WINEARCH=win32` outright. omacellar detects which kind a runner is and tells
you what will actually happen instead of letting wineboot fail.

**Proton knows it is Proton.** Proton runners get built by Proton itself
(`proton runinprefix wineboot -u`), keep their prefix in `<prefix>/pfx`, and are
launched with `runinprefix` rather than the Steam-only `run` verb. They are
registered in Steam's `compatibilitytools.d` on install, so they show up as a
compatibility choice.

**Existing collections count.** If you already have runners on disk, point
`runners_dir` at them and run `runner adopt`. Nothing is copied and nothing is
downloaded; each directory just gains a small `.omacellar.json` describing what
it is, and you gain update checking and installation management.

## Configuration

`~/.omacellar/config.json`, or `omacellar config list`.

| key | meaning |
|---|---|
| `default_runner` | runner used when a prefix does not name one |
| `runners_dir` | where runners live, point at an existing collection to adopt it |
| `prefix_dir` | where installations live |
| `channel` | `stable`, `experimental` or `all`, filters discovery |
| `api_cache_ttl` | seconds to cache GitHub responses, `0` disables caching |
| `steam_compat_tools` | register Proton runners with Steam on install |
| `runner_env` | extra `VAR=VALUE` lines applied to every launch |
| `keep_versions` | keep the replaced version in `Old/` after an update |
| `ascii_art` | draw the logo in `omacellar about` |
| `log_level` | verbosity for session logs |

Environment overrides: `OMACELLAR_HOME`, `OMACELLAR_ROOT`, `GITHUB_TOKEN`,
`STEAM_COMPAT_TOOLS_ROOT`, `NO_COLOR`, `OMACELLAR_ASSUME_YES`.

An older `~/.config/omacellar/config` is imported into `config.json` the first
time omacellar runs, and the old file is left where it is.

Unauthenticated GitHub API calls are limited to 60 per hour. Set `GITHUB_TOKEN`
if you plan on polling a lot.

## Tests

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

It says so up front and skips the network-backed checks when the quota is
gone, rather than reporting failures that have nothing to do with the code.

The full mode takes a few minutes because it boots a real prefix.

## Publishing

`omarchy/PKGBUILD` and `omarchy/omacellar.install` are ready for the
`pkgs.omarchy.org` repository. To submit, open a pull request against the
Omarchy packages repo with a PKGBUILD that points `source` at a tagged release
tarball of this repository, and fill in the real `sha256sums`.