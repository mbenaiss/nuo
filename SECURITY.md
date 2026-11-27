# Security policy

Nuo runs agents that can execute commands on your server, so security reports matter a lot to us.

## Reporting a vulnerability

Please do not open a public issue. Report it privately through GitHub:
**Security** tab of the repository, **Report a vulnerability** (a private security advisory). Include:

- what an attacker can do, and from where (internet, local network, a paired device, a bot);
- the steps or a proof of concept;
- the version or commit you tested.

You should get a first answer within a week. We will work on a fix with you in the advisory, credit you if you wish,
and publish the advisory once a fix is released.

## Scope

In scope: the gateway (`gateway/`), the apps (`ios/`) and the install and deploy scripts. The threat model and the
protections already in place are in [docs/security.md](docs/security.md); its "known limits" are accepted risks,
but a way to go beyond them is in scope.

Out of scope: the agent CLIs themselves (report to their vendors), and a gateway host or Linux account that is
already compromised.

## Supported versions

Only the latest commit of the `main` branch receives security fixes.
