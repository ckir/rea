# Security policy

## What this repository is

`setup.sh` and `setup.ps1` download and run software on your machine: Temurin JDK, Ghidra, `agent-profile`,
`clavity-ls` and `rea`. Read the script before you run it. The README describes what each script does and what
it verifies (a pinned SHA-256 for Ghidra; the vendors' own checksums for the rest).

## Supported versions

Only the latest release is supported. The scripts always install the latest of everything except Ghidra, which is
pinned to the line `rea` supports.

## Reporting a vulnerability

Please report it privately through GitHub: open the repository's **Security** tab and choose **Report a
vulnerability**. Do not open a public issue for something exploitable.

Examples worth reporting: a way to make a script fetch from a host outside its allow-list, to skip a
checksum or archive-safety check, to write outside the tools directory, or to leak a secret into the log.

## What to expect

This is a small project with one maintainer, so there is no response-time guarantee. A report made through
the Security tab stays private until a fix is released.
