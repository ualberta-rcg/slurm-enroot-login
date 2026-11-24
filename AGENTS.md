# Repository Guidelines for Coding Agents

When modifying `slurm-login-pods`:

1. **Keep the repository 100% cluster-agnostic and secret-free.**
   - Target a generic Digital Research Alliance of Canada (DRAC) Slurm + Pyxis/Enroot + SSSD/CCDB + Duo + CVMFS cluster.
   - Never introduce site-specific cluster names, internal URLs, private IP addresses (except RFC 5737 / RFC 3849 documentation blocks `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`, `2001:db8::/32` or unit-test fixtures), `clg_` identifiers, keys, or API tokens.
   - Run `python3 tests/scan_secrets_pii.py` and `python3 -m unittest discover -s tests -v` before every commit.

2. **Preserve security invariants.**
   - `login-gateway/libexec/dispatch` runs unprivileged as the authenticated user.
   - `login-gateway/libexec/route` runs as `root` via `sudo` and must derive identity strictly from `SUDO_USER` (never from untrusted CLI arguments unless `SUDO_USER` is `root` or listed in `SHIM_USERS` with a root-owned `0:0` `/etc/login-gateway/hooks/identity`).
   - `login-gateway/libexec/classify-transfer` must never pass shell metacharacters or unvalidated binaries to the gateway fast-path.
   - Both `images/user` and `images/admin` entrypoints must verify `/etc/slurm-login-pods-release` before starting `sshd`.

3. **Build images in GitHub Actions.**
   - `.github/workflows/test-image.yml` validates branches and PRs without pushing.
   - `.github/workflows/build-push-workflow.yml` builds and publishes user and admin images from `main`.
