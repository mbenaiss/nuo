# Installing Nuo

On a Debian or Ubuntu machine, or a Mac, as the user that will own the gateway:

```sh
curl -fsSL https://raw.githubusercontent.com/mbenaiss/nuo/main/install.sh | bash
```

What it does, its options and how to undo it: [docs/install.md](docs/install.md#one-line-install). Other ways
(demo mode, a gateway from a checkout, a server over ssh): [docs/getting-started.md](docs/getting-started.md).

## For coding agents

If you are a coding agent asked to install Nuo, follow the prompt in
[docs/install-with-an-agent.md](docs/install-with-an-agent.md) that matches the target (this machine, or a server
over ssh). In short:

- ask the user for the checkout folder, port, reachability, service, agents and remote access before changing
  anything; start with `--dry-run`;
- show every `sudo` command and wait for a yes; never open a port, change a firewall, or set up a tunnel or VPN;
- install with `--no-2fa`: the 2FA enrolment and the pairing code print secrets, which the user produces in a
  terminal of their own;
- never print the content of `~/.secrets/nuo.env` or put a secret in a command line or a tracked file;
- check each step against its expected result and end with the report the prompt describes.
