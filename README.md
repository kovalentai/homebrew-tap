# Kovalent Homebrew tap

Homebrew formulae for [Kovalent](https://kovalentai.com) tools.

## Install the Knaix CLI

```sh
brew tap kovalentai/tap
brew install knaix
```

Or in one line, without tapping first:

```sh
brew install kovalentai/tap/knaix
```

Then start a node on your machine:

```sh
knaix local setup
```

Upgrades and removal work the way you expect:

```sh
brew upgrade knaix
brew uninstall knaix
```

Shell completion for bash, zsh, and fish is installed with the binary. No extra step.

## What gets installed

One binary, `knaix`. It is built for macOS and Linux on both Apple Silicon and x86, and it is
downloaded from `releases.knaix.com`. Homebrew checks the SHA-256 of the download against the
checksum recorded in the formula before it installs anything.

If you would rather not use Homebrew, `knaix.com` lists an install script and a direct download you
can verify yourself.

## About this repo

This repo holds the formula only. The CLI source lives elsewhere. The formula is updated
automatically when a new version of the CLI is published, and the update is refused unless the
binaries it points at are already live.

Docs: [knaix.com](https://knaix.com) &middot; Issues with the CLI itself belong on the Kovalent
issue tracker, not here.

The first install from any third-party tap asks you to trust it. That is Homebrew asking, not us,
and it is the same prompt you get for every tap outside homebrew-core.
