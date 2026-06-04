# Arch Linux packaging

`PKGBUILD` builds the Lean library, CLI, and daemon with the distro `lean4`
package and installs:

- `/usr/bin/leancli`
- `/usr/bin/leancli-daemon`
- `/usr/lib/systemd/user/leancli.socket`
- `/usr/lib/systemd/user/leancli.service`
- `/usr/share/doc/leancli-git/` project docs

Enable socket activation with:

```bash
systemctl --user enable --now leancli.socket
```

Before publishing, replace `_repo_url` and `url` with the canonical
leanCLI repository URL. The `optdepends` entries are intentionally
host-integration tools only:

- `tpm2-tools` for TPM2 provisioning and inspection
- `libfido2` for FIDO2 security-key provisioning and inspection
- `fprintd` for optional biometric enrollment

The Lean modules do not link to those libraries or use them as crypto
implementations.
