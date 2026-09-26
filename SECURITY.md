# Security policy

Troupe runs agents that execute shell commands, on people's laptops and on their
clusters, with their credentials. A flaw here can hand that to somebody else, so we treat
a report as urgent and keep it private until a fix is out.

## Reporting a vulnerability

Please do not open a public issue. Report it privately, through GitHub:

* the repository's **Security** tab, then **Report a vulnerability**
  ([direct link](https://github.com/it-minds/troupe/security/advisories/new)). It opens a
  private advisory that only you and the maintainers can see.
<!-- There is no security address yet. When there is one, it is one more line here. -->

Say what is affected (the daemon, the TUI, the desktop app, the plane or another image,
the chart, an install script) and which version, how to reproduce it, and what an
attacker gains. A proof of concept helps; a fix is welcome but not expected.

## What we promise

* An acknowledgement within **5 business days**, from a person.
* An answer on whether we accept it as a vulnerability and what we plan to do, and
  updates in the advisory as that changes.
* A fix in a release, and the advisory published with it, crediting you unless you ask us
  not to.

We ask that you do not disclose it publicly until the fix is released or 90 days have
passed since your report, whichever comes first. If you believe users are being attacked
through it now, say so in the report and we will move faster.

## Supported versions

Troupe is in beta, and fixes go into the next release rather than into older ones.

| Version | Security fixes |
|---|---|
| The latest 0.5.x beta release | yes |
| Anything older, and pre-releases (`-pre.N`) | no: upgrade to the latest release |

The images and the chart are versioned with everything else, so the same holds for a
cluster deployment.
