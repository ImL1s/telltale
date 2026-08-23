# Security Policy

## Supported versions

Security fixes target the current `main` branch and, when practical, the latest
GitHub prerelease. Older builds may remain vulnerable and are not supported.

## Report a vulnerability privately

Use the repository's **Security** tab to submit a private
[GitHub Security Advisory](https://github.com/ImL1s/telltale/security/advisories/new)
when that option is available. If it is unavailable, contact the maintainer
privately through the [ImL1s GitHub profile](https://github.com/ImL1s) before
publishing details.

Include the affected version or commit, platform, impact, reproduction steps,
and the smallest redacted evidence needed to verify the issue. Allow reasonable
time for triage and remediation before public disclosure.

Never put the following in a public issue, discussion, pull request, or log:

- secrets, access tokens, or private keys;
- a raw VIN or a complete diagnostic transcript;
- signing keys, keystores, passwords, or signing configuration;
- personal device identifiers that are not needed to reproduce the issue.

For an ordinary bug with no security or privacy impact, use the public issue
tracker after removing sensitive vehicle and device data.

## Safety boundary

Security review reduces software risk; it does not certify an adapter, vehicle,
diagnosis, or repair. Telltale provides no safety guarantee. Do not operate the
app while driving, and do not rely on a result as proof that a vehicle is safe.
