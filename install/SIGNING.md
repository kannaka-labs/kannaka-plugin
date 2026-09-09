# Installer trust — verifying & signing the native installers

Every tagged release attaches three native installers built by
`release-installers.yml`:

| Artifact | Platform |
|---|---|
| `kannaka-setup-linux.deb`   | Linux (Debian/Ubuntu) |
| `kannaka-setup-macos.pkg`   | macOS |
| `kannaka-setup-windows.msi` | Windows |

There are **two independent layers of trust**:

- **Layer 1 — always on, free (no certs).** A signed `SHA256SUMS` manifest plus
  a per-artifact Sigstore *keyless* signature. This ships on every release with
  nothing to configure. Covered in **[Verify a download](#verify-a-download)**.
- **Layer 2 — optional, cert-gated.** OS-native code signing (Windows
  Authenticode, macOS Developer ID + notarization) that additionally silences
  SmartScreen / Gatekeeper. Needs paid certs. Covered in
  **[Enable OS-native signing](#enable-os-native-signing)**.

> The engine binary itself (downloaded by `install.sh` / `install.ps1` from the
> `kannaka-memory` releases) is separately `sha256`-verified by those installers
> against the `.sha256` sidecar published next to each binary — so the download
> path is checksum-checked end to end even before Layer 2.

---

## Verify a download

Every release includes, alongside the three installers:

- `<artifact>.sha256` — a per-file checksum sidecar next to each installer
- `SHA256SUMS.txt` — one manifest with the checksums of all three installers
- `<artifact>.sig` + `<artifact>.pem` — a cosign keyless signature and its
  short-lived certificate, for each installer **and** for `SHA256SUMS.txt`
  (present unless a Sigstore outage skipped signing — see the note at the end)

### 1. Checksums

```bash
# in the folder holding the installer(s) + SHA256SUMS.txt
sha256sum -c SHA256SUMS.txt 2>/dev/null              # Linux (all three)
shasum -a 256 -c SHA256SUMS.txt                      # macOS (all three)
sha256sum -c kannaka-setup-linux.deb.sha256          # or just one file, via its sidecar
# Windows PowerShell (single file):
#   (Get-FileHash .\kannaka-setup-windows.msi -Algorithm SHA256).Hash
#   # compare against the matching line in SHA256SUMS.txt
```

### 2. Sigstore signature (proves it was built by *this* repo's release workflow)

Install [cosign](https://docs.sigstore.dev/cosign/installation/), then verify
any artifact — here the checksums manifest itself:

```bash
cosign verify-blob \
  --certificate      SHA256SUMS.txt.pem \
  --signature        SHA256SUMS.txt.sig \
  --certificate-identity-regexp '^https://github\.com/kannaka-labs/kannaka-plugin/\.github/workflows/release-installers\.yml@refs/tags/v' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS.txt
```

Swap `SHA256SUMS.txt` for `kannaka-setup-windows.msi` (and its `.pem`/`.sig`) to
verify an installer directly. A successful verify means the signature was
produced by the `release-installers.yml` workflow of `kannaka-labs/kannaka-plugin`
on a `v*` tag — recorded in the public [Rekor](https://docs.sigstore.dev/logging/overview/)
transparency log. No shared key or downloaded public key is involved; the
identity *is* the proof.

### What you'll still see (SmartScreen / Gatekeeper)

The Sigstore signature is **not** an OS-native code signature. Windows
SmartScreen and macOS Gatekeeper only consult their own trust chains
(Authenticode / Apple Developer ID) — they do **not** check Rekor — so until the
Layer-2 certs below are configured you will still get an "unrecognized
publisher / unidentified developer" prompt on first run:

- **Windows**: SmartScreen "Windows protected your PC" → *More info* → *Run anyway*.
- **macOS**: Gatekeeper "cannot verify the developer" → *System Settings › Privacy
  & Security › Open Anyway* (or `xattr -d com.apple.quarantine kannaka-setup-macos.pkg`).

That prompt is expected and does not mean the download is untrusted — it means
the OS can't vouch for it *for you*. The checksum + `cosign verify-blob` above
let you establish trust yourself; Layer 2 removes the prompt entirely.

---

## Enable OS-native signing

**come-back checklist.** `release-installers.yml` **already has the Authenticode /
Apple signing steps wired in**. They're inert until you add the cert secrets
below. **You don't edit any workflow code** — just add the GitHub secrets, then
cut a new tag. `HAS_SIGN` flips to `true` automatically and the `.msi` / `.pkg`
come out signed (+ notarized on macOS).

> The `.deb` is **not** OS-code-signed — Linux trust is repo-level GPG (apt), not
> per-file. Layer-1 checksum + Sigstore signature still cover it.

### First: prove the plumbing without buying anything

The signing steps had never executed — they were written, wired, and inert. Every
other never-executed path in this repo turned out to be broken the first time it
ran, and finding that out on the release *after* a certificate purchase is the
expensive way round.

So there is a smoke test. It forges a throwaway self-signed certificate, pushes
it through the **same** signing step the real secrets use, and asserts a
signature came out:

```bash
gh workflow run release-installers.yml --repo kannaka-labs/kannaka-plugin \
  -f sign_smoke_test=true
```

It publishes nothing. What it proves is everything except trust: that the base64
decode works, that `signtool.exe` is found (newest SDK, x64), that the sign
invocation is well-formed, and that the verify step can tell a signed artifact
from an unsigned one.

It also asserts the **failure**: a self-signed certificate must NOT report
`Valid`, because a check that passes for a worthless certificate is not checking
anything. A green run looks like this:

```
signtool: C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe
Successfully signed: kannaka-setup-windows.msi
status: UnknownError  signer: CN=Kannaka Smoke Test
notice: smoke test: the msi was signed and the untrusted chain was correctly rejected
```

With a real certificate the only thing that changes is `status: Valid`. If it is
anything else, the build now **fails** rather than publishing an unsigned
installer under a release that claims to be signed.

### Windows (.msi — Authenticode)

> **Status: deliberately not done.** The `.msi` ships unsigned, and that is a
> decision rather than an omission — see *Why Windows is unsigned* below before
> spending anything.

#### What changed, and why the instructions below may not apply to you

Since the CA/Browser Forum tightened its baseline requirements in **June 2023**,
the private key for a new code-signing certificate must live on certified
hardware — a USB token, or a CA-operated cloud HSM. **You can no longer be
issued a plain `.pfx` for a new OV certificate**, which is what the workflow's
existing signing step consumes.

That leaves three shapes:

| Route | Fits CI? | Notes |
|---|---|---|
| USB hardware token | ✗ | Nothing is plugged into a GitHub-hosted runner. Needs a self-hosted runner with the token attached. |
| Cloud HSM signing (Azure Trusted Signing, SSL.com eSigner, DigiCert KeyLocker) | ✓ | The CA holds the key; you call their tool. Each needs a **different** signing step than the one in this workflow. |
| A `.pfx` issued **before** June 2023 | ✓ | Still works with the step below, until it expires. |

If you go the cloud route, the `WINDOWS_CERT_PFX_BASE64` path is not what you
want — the signing step has to be replaced with that vendor's action or CLI.
Azure Trusted Signing is much the cheapest but normally wants ~3 years of
verifiable business history for organisation Public Trust; SSL.com eSigner has
fewer qualifying hoops at higher cost.

#### Why Windows is unsigned

A paid OV certificate **does not** immediately silence SmartScreen. Reputation
accrues per-publisher over downloads, so a freshly-issued certificate can still
produce "Windows protected your PC" for weeks. The spend buys an eventual
outcome, not an immediate one — and at this download volume that outcome arrives
slowly.

Meanwhile Layer 1 already gives anyone who cares a way to verify the download
completely: `SHA256SUMS.txt` plus a Sigstore signature tied to this repository's
release workflow. That is stronger evidence of provenance than Authenticode
provides; it is simply not evidence the *operating system* consults.

Revisit when download volume makes the warning a real cost, or when Azure
Trusted Signing eligibility comes through.

#### If you do have a pre-2023 `.pfx`

```bash
# 1. base64-encode the .pfx (one line, no wrapping)
#    macOS/Linux:
base64 -i kannaka-cert.pfx | tr -d '\n' > cert.b64
#    Windows PowerShell:
#    [Convert]::ToBase64String([IO.File]::ReadAllBytes("kannaka-cert.pfx")) | Set-Content cert.b64

# 2. add the two secrets
gh secret set WINDOWS_CERT_PFX_BASE64 --repo kannaka-labs/kannaka-plugin < cert.b64
gh secret set WINDOWS_CERT_PASSWORD   --repo kannaka-labs/kannaka-plugin   # paste the .pfx password

rm cert.b64
```

### macOS (.pkg — Developer ID Installer + notarization)

> **The trap, first.** Apple issues several certificate types and only one signs
> a `.pkg`:
>
> | Certificate | Signs | Use here |
> |---|---|---|
> | **Developer ID Installer** | `.pkg` installers | ✅ this one |
> | Developer ID Application | `.app` bundles | ✗ cannot sign a `.pkg` |
> | Apple Development / Distribution | App Store builds | ✗ |
>
> They sit next to each other in the developer portal and are easy to mix up.
> On a Mac, check what you actually hold:
>
> ```bash
> security find-identity -v | grep "Developer ID"
> ```
>
> The line you want reads `Developer ID Installer: Your Name (TEAMID)` — that
> whole quoted string, including the team id in brackets, is `MACOS_SIGN_IDENTITY`,
> and the ten characters in the brackets are `MACOS_NOTARY_TEAM_ID`.
>
> Once `MACOS_CERT_P12_BASE64` and `MACOS_CERT_PASSWORD` are set you can have CI
> tell you, without cutting a release:
>
> ```bash
> gh workflow run release-installers.yml --repo kannaka-labs/kannaka-plugin \
>   -f sign_smoke_test=true
> ```
>
> It imports the `.p12`, prints every identity it contains, fails loudly if
> there is no Installer identity, and signs a throwaway copy of the `.pkg` to
> prove `productsign` accepts it. It deliberately stops before notarisation —
> that needs three more secrets, and the mistake being hunted happens earlier.

You need: a **"Developer ID Installer"** certificate exported as `.p12`, and an
**app-specific password** for `notarytool` (appleid.apple.com → Sign-In and Security).

```bash
# 1. base64-encode the .p12
base64 -i developerid-installer.p12 | tr -d '\n' > cert.b64

# 2. add the secrets
gh secret set MACOS_CERT_P12_BASE64 --repo kannaka-labs/kannaka-plugin < cert.b64
gh secret set MACOS_CERT_PASSWORD   --repo kannaka-labs/kannaka-plugin   # the .p12 export password
gh secret set MACOS_SIGN_IDENTITY   --repo kannaka-labs/kannaka-plugin   # e.g. "Developer ID Installer: Nick Flach (TEAMID)"
gh secret set MACOS_NOTARY_APPLE_ID --repo kannaka-labs/kannaka-plugin   # your Apple ID email
gh secret set MACOS_NOTARY_TEAM_ID  --repo kannaka-labs/kannaka-plugin   # 10-char Team ID
gh secret set MACOS_NOTARY_PASSWORD --repo kannaka-labs/kannaka-plugin   # app-specific password

rm cert.b64
```

### Then: trigger a signed build

```bash
git -C kannaka-plugin tag -f v1.4.1            # any new tag works; bump versions first if you like
git -C kannaka-plugin push -f origin v1.4.1
# watch:
gh run watch --repo kannaka-labs/kannaka-plugin
```

The Actions log will show **"Sign .msi …"** / **"Sign + notarize .pkg …"** running
(instead of being skipped). The release assets `kannaka-setup-windows.msi` and
`kannaka-setup-macos.pkg` are then signed — no SmartScreen / Gatekeeper warnings.

### Secrets at a glance

| Secret | Platform | What it is |
|---|---|---|
| `WINDOWS_CERT_PFX_BASE64` | win | base64 of the Authenticode `.pfx` |
| `WINDOWS_CERT_PASSWORD` | win | `.pfx` password |
| `MACOS_CERT_P12_BASE64` | mac | base64 of the Developer ID Installer `.p12` |
| `MACOS_CERT_PASSWORD` | mac | `.p12` export password |
| `MACOS_SIGN_IDENTITY` | mac | "Developer ID Installer: …" identity string |
| `MACOS_NOTARY_APPLE_ID` | mac | Apple ID email |
| `MACOS_NOTARY_TEAM_ID` | mac | Team ID |
| `MACOS_NOTARY_PASSWORD` | mac | app-specific password |
