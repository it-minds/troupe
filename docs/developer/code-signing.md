# Buying and setting up OS code signing

For the people who provision accounts for the organisation that releases Troupe: what to
buy so that macOS and Windows recognise the apps as that organisation's, what each purchase
needs first, what it costs, how long each step takes, and which secrets go into the
repository's `release` environment. When they are there, the next release is signed with no other change: the workflows, the scripts and the docs are ready ([section 6](#6-the-day-the-certificates-exist)).

Troupe's own check does not depend on any of this. Every release is signed with the release
key, and every client verifies that signature before it installs anything
([Decision 865](../decisions/0865-releases-are-signed-and-troupe-update-installs-only-what-the-release-key-signed.md),
[security.md §5](../admin/security.md#5-releases-signed-and-verified)). An operating
system does not know that key, so today macOS's Gatekeeper and Windows's SmartScreen warn
the first time an app runs, and the install docs say how to open it
([security.md §6](../admin/security.md#6-the-apps-are-not-os-code-signed)). OS signing is
added on top of the release key, never in its place.

Prices, eligibility and processes change. Each fact below that can change links to where it
was read, and [the sources](#sources) list them with the date. Read them again before
paying for anything.

## 1. What signing buys, and what it does not

| | macOS | Windows |
| --- | --- | --- |
| Unsigned, today | Gatekeeper refuses an app downloaded in a browser until the person allows it in System Settings | SmartScreen shows "Windows protected your PC" for a downloaded setup; Smart App Control, where it is on, blocks unsigned programs outright |
| Signed | Developer ID signed and notarised: the app opens after the usual question about an app from the internet | the publisher's verified name in the prompt; Smart App Control lets a validly signed program run |
| Still not solved by signing | for an app, nothing; for `troupe` and `troupe-daemon`, Gatekeeper looks their notarisation up online, since a standalone binary cannot carry it | SmartScreen reputation builds from downloads, so the first signed releases can still be warned about |

Two facts decide how much has to be signed:

- **Smart App Control checks every program, not only downloads.** Microsoft's guidance is
  that on Windows 11 it "will block execution of unsigned files unless the file has a
  positive reputation", and that its checks "apply to all executable files, not just those
  downloaded from the Internet"
  ([SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation),
  [Smart App Control FAQ](https://support.microsoft.com/en-us/windows/smart-app-control-frequently-asked-questions-285ea03d-fa88-4d56-882e-6698afdb7003)).
  `install.ps1` downloads with `Invoke-WebRequest`, which sets no mark of the web, so
  SmartScreen rarely asks about the binaries; Smart App Control still checks them. So
  every `.exe` and `.dll` Troupe ships needs a signature: the desktop app, `troupe.exe`, and the
  Erlang runtime and native libraries inside `troupe-daemon` (25 files in 0.15.0) and inside
  `troupe.exe`'s payload, which it unpacks under `%APPDATA%\.burrito` on first run (57).
- **EV certificates no longer buy SmartScreen reputation.** Microsoft: "EV certificates no
  longer bypass SmartScreen ... Paying a premium for EV solely to avoid SmartScreen warnings
  is no longer justified"
  ([SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)).
  One vendor's page still advertises an "immediate SmartScreen reputation benefit" for EV
  while its own FAQ says the opposite since 2024
  ([SSL.com EV](https://www.ssl.com/products/software-integrity/code-signing/ev/),
  [SSL.com OV](https://www.ssl.com/products/software-integrity/code-signing/ov/)).
  Microsoft's page is the one that decides.

## 2. Apple: a Developer ID, and notarisation

### What to buy

**The Apple Developer Program, enrolled as an organisation.** 99 USD per membership year;
prices vary by region and are shown in local currency during enrolment. A nonprofit, an
accredited educational institution or a government entity can ask for a fee waiver
([enrol](https://developer.apple.com/programs/enroll/)). The free Apple account cannot
notarise ([Tauri, macOS signing](https://v2.tauri.app/distribute/sign/macos/)).

### What has to exist first

From [Apple's enrolment page](https://developer.apple.com/programs/enroll/) and
[its D-U-N-S page](https://developer.apple.com/help/account/membership/D-U-N-S/):

- **A legal entity** that can enter into contracts with Apple. DBAs, fictitious business
  names, trade names and branches are not accepted, and a sole proprietorship enrols as an
  individual instead.
- **A D-U-N-S Number** registered to that legal entity (not needed for a government
  organisation). Look the organisation up first: Dun & Bradstreet may already have
  assigned one. If not, request one, free: allow up to 5 business days from D&B (expediting
  does not shorten it; after two weeks, email D&B), then up to 2 business days for Apple to
  receive it. D&B may call for the business type or headcount, so have the registration
  documents to hand.
- **A public, working website** on a domain associated with the organisation; a social
  media page or a registrar's placeholder is refused.
- **A work email** on the organisation's domain.
- **An Apple Account with two-factor authentication**, in the enrolling person's legal first
  and last names, preferably on the organisation's email address.

### Who the Account Holder is

The person who enrols becomes the **Account Holder** and must have the legal authority to
bind the organisation: its owner or founder, an executive, a senior project lead, or an
employee given that authority by a senior employee. Someone who is not the owner or founder
gives a reference who can confirm it
([enrol](https://developer.apple.com/programs/enroll/),
[enrolment help](https://developer.apple.com/help/account/membership/program-enrollment/)).

**Only the Account Holder can create a Developer ID Application certificate**, and there can
be up to five of them at a time; admins can be given access to cloud-managed Developer ID
certificates
([Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)).
So choose an Account Holder who will stay with the organisation, not whoever happens to cut
the next release, and add the people who run releases as team members with the Admin role.

### The certificate

1. On a Mac, create a certificate signing request (Keychain Access, **Certificate
   Assistant → Request a Certificate From a Certificate Authority**).
2. In **Certificates, Identifiers & Profiles → Certificates → +**, choose **Developer ID →
   Developer ID Application**, upload the request, and download the `.cer`
   ([Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)).
3. Open the `.cer` so it lands in the login keychain, then export the certificate *with its
   private key* as a `.p12` with a password, and base64 it:
   `openssl base64 -A -in developer-id.p12 -out developer-id.txt`
   ([Tauri, macOS signing](https://v2.tauri.app/distribute/sign/macos/)).
4. `security find-identity -v -p codesigning` prints the signing identity,
   `Developer ID Application: <legal name> (<team id>)`.

An app signed while the certificate was valid keeps opening after it expires; a new
certificate is needed only to sign new releases. A revoked certificate stops every app it
signed from installing or launching
([Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)).
Keep the `.p12` and its password nowhere but the `release` environment and the
organisation's own secret store.

### Notarisation

Notarisation is Apple scanning a Developer ID signed build and issuing a ticket Gatekeeper
checks. What it requires: every executable signed with a Developer ID certificate, the
hardened runtime on, a secure timestamp, and no `get-task-allow` entitlement
([notarizing](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)).
It is done with `xcrun notarytool`; `altool` stopped working on 1 November 2023. Most
submissions finish within 5 minutes and 98 percent within 15, and Apple asks for no more than
75 a day. A ticket can be stapled to an app, a disk image or a package, but **not to a
standalone binary**: for `troupe` and `troupe-daemon` Gatekeeper finds the ticket online
([customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)).

`notarytool` signs in one of two ways:

| | what it is | for CI |
| --- | --- | --- |
| **An App Store Connect API key** (recommended) | a **team** key, made in App Store Connect under **Users and Access → Integrations → App Store Connect API → Team Keys** by someone with the Admin role. The private key (`.p8`) downloads once; Apple keeps no copy. Individual keys cannot use `notarytool` ([API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)). Tauri's guide gives it the Developer access ([Tauri, macOS signing](https://v2.tauri.app/distribute/sign/macos/)) | belongs to the team, not to a person; revoked on its own |
| An Apple Account and an app-specific password | `--apple-id`, `--team-id` and an app-specific password, since every account has two-factor authentication ([customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)) | ties releases to one person's account |

### Secrets for the `release` environment

| secret | what goes in it |
| --- | --- |
| `APPLE_CERTIFICATE` | the base64 of the Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | the `.p12`'s export password |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: <legal name> (<team id>)` |
| `APPLE_API_ISSUER` | the Issuer ID shown above the Team Keys table |
| `APPLE_API_KEY` | the key's Key ID |
| `APPLE_API_PRIVATE_KEY` | the text of the `.p8` file |

tauri-action takes the key as `APPLE_API_KEY_PATH`, **the path of the `.p8` file**, not its
contents ([Tauri, macOS signing](https://v2.tauri.app/distribute/sign/macos/)), and a secret
cannot be a file on the runner. So the key's text goes in as `APPLE_API_PRIVATE_KEY`, and
`native.yml` writes it to a file only the job reads; there is no `APPLE_API_KEY_PATH` secret.

## 3. Windows: three ways to get a signature

Every option below is a publicly trusted Authenticode signature. Since 1 June 2023 the
private key of any publicly trusted code-signing certificate has to be generated, kept and
used in a hardware crypto module, and a certificate issued on or after 1 March 2026 is
valid for at most 460 days
([CA/Browser Forum code signing requirements](https://cabforum.org/working-groups/code-signing/requirements/)).
So there is no certificate file to download any more: the key lives in a token or a cloud
HSM, and a hosted CI runner can only reach the cloud kind.

| | Microsoft Artifact Signing (was Trusted Signing) | OV certificate in a CA's cloud HSM | EV certificate |
| --- | --- | --- | --- |
| Who can use it | organisations in the United States, Canada, the EU, the UK, Australia, New Zealand, Japan, South Korea, Singapore, Switzerland, Norway and Israel; individual developers in the US and Canada only. Needs a paid Azure subscription: free, trial and sponsored ones are refused ([quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart), [FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq)) | any legal entity the CA can validate, anywhere it sells | the same, with stricter validation |
| What it costs | Basic 9.99 USD a month for 5,000 signatures, Premium 99.99 USD for 100,000, then 0.005 USD a signature; billed in full for the month, not pro rata ([pricing](https://azure.microsoft.com/en-us/pricing/details/artifact-signing/), [FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq)) | for example 129 USD a year for SSL.com's OV certificate plus its eSigner cloud signing, 20 USD a month for 20 signatures or 85 USD for 100 ([OV](https://www.ssl.com/products/software-integrity/code-signing/ov/), [eSigner pricing](https://www.ssl.com/guide/esigner-pricing-for-code-signing/)); or DigiCert's OV certificate with KeyLocker cloud storage from 83 USD a month, 996 USD a year ([DigiCert](https://www.digicert.com/signing/code-signing-certificates)) | for example 349 USD a year at SSL.com, and its EV cloud signing from 100 USD a month for 10 signatures ([EV](https://www.ssl.com/products/software-integrity/code-signing/ev/), [eSigner pricing](https://www.ssl.com/guide/esigner-pricing-for-code-signing/)) |
| How long until it signs | identity validation takes 1 to 20 business days, longer if more documents are asked for; it is done in the Azure portal only ([quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)) | SSL.com's standard validation is 3 to 5 days, after a callback to a listed phone number ([OV](https://www.ssl.com/products/software-integrity/code-signing/ov/)) | the same order, with more checks |
| The key | in Microsoft's HSMs (FIPS 140-3 Level 3); the certificate is never handed out and renews itself ([FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq)) | in the CA's cloud HSM; a USB token instead cannot be reached from a hosted runner | the same |
| SmartScreen | reputation builds from downloads | the same | the same: EV no longer bypasses it, and Artifact Signing issues no EV ([SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation), [FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq)) |

A release signs about a dozen files on Windows: about three in `troupe-daemon`'s payload,
five in `troupe.exe`'s, the desktop app's executable and its installers. The payloads hold
about 80 PE files between them, but most are the Erlang runtime's own, which Ericsson AB
already signs, and `scripts/signing/sign-windows.ps1` leaves a file that carries a valid
signature as it is; what is left to sign is what the build makes itself. A tier priced per
signature is sized for that, times the releases in a month.

**Where the sources disagree: how old an organisation must be.** Microsoft's quickstart and
FAQ for Artifact Signing, as read, state no minimum age. Search results quoting the earlier
Trusted Signing quickstart say it onboarded only entities with three or more years of
verifiable tax history, and an answer on Microsoft Q&A says validation needs "at least three
years of operational history"
([Q&A](https://learn.microsoft.com/en-us/answers/questions/2110155/need-help-with-identity-validation-for-azure-trust)).
An organisation younger than that should expect a refusal to be possible. A refused
validation cannot be argued further once the three chances to add documents are used
([FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq)).

### The recommendation: Artifact Signing, Basic

If the organisation is in one of the listed countries and passes identity validation,
use **Microsoft Artifact Signing on the Basic plan**:

- **It is the cheapest**: 9.99 USD a month covers a release's dozen signatures hundreds of
  times over, where a CA's cloud signing priced per signature costs 20 USD a month for 20
  signatures, about one release, on top of the certificate's 129 USD a year.
- **No key to hold.** The service "automatically manages your certificate lifecycle"
  ([pricing](https://azure.microsoft.com/en-us/pricing/details/artifact-signing/)), so there
  is no `.pfx`, no token and no reissue every 460 days to remember.
- **It is what the repository already expects.** `native.yml` and
  `tauri.signing.conf.json` call it, and Tauri documents it
  ([Tauri, Windows signing](https://v2.tauri.app/distribute/sign/windows/)).
- **Microsoft recommends it** for apps distributed outside the Store, and SmartScreen treats
  it as it treats any OV or EV certificate
  ([SmartScreen reputation](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation)).

If the organisation is outside those countries, or validation is refused, buy an **OV
certificate kept in the CA's cloud HSM, with a signing API CI can call**, sized for the
signature count above. Do not buy EV for this.

### Setting up Artifact Signing

From the [quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart)
and the [FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq):

1. A paid Azure subscription in a Microsoft Entra tenant.
2. Register the `Microsoft.CodeSigning` resource provider on the subscription.
3. Create an **Artifact Signing account** in a region that offers it (West Europe, North
   Europe, East US and others; the quickstart lists each region's endpoint, such as
   `https://weu.codesigning.azure.net`), on the Basic pricing tier.
4. Give the person who validates the **Artifact Signing Identity Verifier** role, then
   create an **organisation, public** identity validation: the legal entity's name, website,
   a business identifier, the address, a monitored primary email on the organisation's domain
   that accepts external links (the link expires in seven days), a different secondary email
   on the same domain, and the person who will verify themselves with a government ID. Keep
   the entity's public records up to date first; documents asked for must have been issued in
   the last 12 months.
5. When the validation reads **Completed**, create a **Public Trust** certificate profile
   that uses it.
6. An app registration (service principal) for CI, given the **Artifact Signing
   Certificate Profile Signer** role on the account or the profile, and a client secret for
   it. The signing tool Tauri uses reads exactly these
   ([artifact-signing-cli](https://github.com/levminer/trusted-signing-cli)). Microsoft's own
   GitHub Action can instead sign in with OpenID Connect and no client secret
   ([artifact-signing-action](https://github.com/Azure/artifact-signing-action)); `native.yml`
   signs everything with `artifact-signing-cli` and the client secret today.

The identity validation is renewed before it expires; Azure starts reminding 60 days
before, and signing stops if it lapses
([FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq)).

### Secrets for the `release` environment

| secret | what goes in it |
| --- | --- |
| `AZURE_TENANT_ID` | the Entra tenant's ID |
| `AZURE_CLIENT_ID` | the app registration's client ID |
| `AZURE_CLIENT_SECRET` | its client secret (not needed for steps that sign in with OpenID Connect) |
| `AZURE_ENDPOINT` | the account's regional endpoint, such as `https://weu.codesigning.azure.net` |
| `AZURE_CODE_SIGNING_NAME` | the Artifact Signing account's name |
| `AZURE_CERT_PROFILE_NAME` | the certificate profile's name |

These are the names `native.yml` reads; setting `AZURE_ENDPOINT` is what turns its Windows
signing on, and the other five must be set with it. With the OV fallback the names are the
CA's instead (its signing API's user, password or key, and the credential's ID), and
`scripts/signing/sign-windows.ps1` needs a third `TROUPE_SIGN_TOOL` beside `artifact-signing`
and `signtool`.

## 4. The `release` environment

The secrets above go into the repository's **`release` environment**, beside
`RELEASE_MINISIGN_KEY`, never into repository secrets. Today that environment accepts jobs
from `main` only and has no required reviewers. Environment secrets reach only the jobs that
name the environment, and only once its rules pass
([GitHub, managing environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)).
So `release.yml` calls `native.yml` with `sign: release`, and only then do its macOS and
Windows builds, and the small job that sees which secrets are set, name `release`. The
nightly (on `main`), a pre-release (from any branch, which the environment would refuse)
and a pull request call it without `sign`: they build unsigned, never ask for the
environment, and read no secret. Keep the main-only rule: it is what keeps the
certificates to the release workflow on `main`.

Someone with admin rights on the repository adds them, under **Settings → Environments →
release → Environment secrets**. Nobody else needs to see the values, and nothing in the
repository prints them.

## 5. The order of work

| | step | who | usually takes |
| --- | --- | --- | --- |
| 1 | Name the legal entity that releases Troupe, and the person who will be its Apple Account Holder | the organisation | a decision |
| 2 | Look up or request the D-U-N-S Number | the Account Holder | up to 5 business days, then up to 2 for Apple to see it |
| 3 | In parallel: a paid Azure subscription, the resource provider, the Artifact Signing account, and the identity validation request | an Azure administrator, and the person who verifies with a government ID | an hour of setup, then 1 to 20 business days of validation |
| 4 | Enrol in the Apple Developer Program as the organisation, agree to the licence and pay | the Account Holder | Apple publishes no duration for its verification; allow for a call to the reference |
| 5 | Create the Developer ID Application certificate and export the `.p12`; create the team API key | the Account Holder; an Admin for the key | an hour |
| 6 | Create the certificate profile, the app registration and its role | an Azure administrator | an hour, once validation is complete |
| 7 | Put the twelve secrets into the `release` environment | a repository admin | minutes |
| 8 | Nothing: the release workflow is wired and tested ([next section](#6-the-day-the-certificates-exist)) | — | — |
| 9 | The first signed release; open it on a fresh Mac and a fresh Windows machine | the maintainer | a release |

Steps 2 to 4 are the long ones and run in parallel: by the figures above, from about a week
to four or more, most of it waiting on others. Nothing in steps 1 to 7 changes the
repository.

## 6. The day the certificates exist

Everything but the certificates is in the repository and is tested on every change to it
([Decision 938](../decisions/0938-os-signing-is-wired-off-until-the-secrets-exist-and-signs-everything-a-payload-unpacks.md)):
the secrets go into the `release` environment and the next release is signed.
[signing-day.md](signing-day.md) is the runbook: what signs what, the twelve secrets, the
one-time setup, checking the first signed release, and a rejected notarisation.

## Sources

Each read on 2026-10-12, in a browser, or for the two repositories and the crate through
GitHub's and crates.io's own APIs.

| source | what it gave |
| --- | --- |
| [Apple: Become a member](https://developer.apple.com/programs/enroll/) | price, fee waiver, organisation requirements, Account Holder's authority |
| [Apple: D-U-N-S Number](https://developer.apple.com/help/account/membership/D-U-N-S/) | who needs one, lookup, 5 + 2 business days |
| [Apple: Enrollment](https://developer.apple.com/help/account/membership/program-enrollment/) | the reference for binding authority |
| [Apple: Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) | Account Holder only, five certificates, expiry and revocation |
| [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) | what notarisation requires |
| [Apple: Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) | `notarytool`, timings, 75 a day, no stapling to a standalone binary |
| [Apple: Creating API keys for App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api) | team keys, Admin role, `.p8` once, individual keys cannot notarise |
| [Tauri: macOS code signing](https://v2.tauri.app/distribute/sign/macos/) | `.p12` export, `APPLE_*` variables, `APPLE_API_KEY_PATH` is a path |
| [Tauri: Windows code signing](https://v2.tauri.app/distribute/sign/windows/) | Artifact Signing through `artifact-signing-cli` |
| [Microsoft: Artifact Signing quickstart](https://learn.microsoft.com/en-us/azure/artifact-signing/quickstart) | countries, regions, identity validation, 1 to 20 business days |
| [Microsoft: Artifact Signing FAQ](https://learn.microsoft.com/en-us/azure/artifact-signing/faq) | paid subscription, no EV, key handling, renewal, three attempts |
| [Microsoft: Artifact Signing pricing](https://azure.microsoft.com/en-us/pricing/details/artifact-signing/) | Basic and Premium |
| [Microsoft Q&A: identity validation for Trusted Signing](https://learn.microsoft.com/en-us/answers/questions/2110155/need-help-with-identity-validation-for-azure-trust) | the three-year history answer |
| [Microsoft: SmartScreen reputation for Windows app developers](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation) | EV no longer bypasses SmartScreen; Smart App Control checks every executable |
| [Microsoft: Smart App Control FAQ](https://support.microsoft.com/en-us/windows/smart-app-control-frequently-asked-questions-285ea03d-fa88-4d56-882e-6698afdb7003) | unsigned and unknown apps are blocked |
| [CA/Browser Forum: Code Signing Baseline Requirements](https://cabforum.org/working-groups/code-signing/requirements/) | hardware key storage since 2023-06-01, 460 days from 2026-03-01 |
| [SSL.com: OV code signing](https://www.ssl.com/products/software-integrity/code-signing/ov/), [EV code signing](https://www.ssl.com/products/software-integrity/code-signing/ev/), [eSigner pricing](https://www.ssl.com/guide/esigner-pricing-for-code-signing/) | one CA's prices and validation times |
| [DigiCert: code signing certificates](https://www.digicert.com/signing/code-signing-certificates) | another CA's price with cloud key storage |
| [GitHub: managing environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments) | environment secrets reach only the jobs that use the environment |
| [Azure/artifact-signing-action](https://github.com/Azure/artifact-signing-action) | Microsoft's GitHub Action, OpenID Connect |
| [artifact-signing-cli](https://github.com/levminer/trusted-signing-cli), [crates.io: trusted-signing-cli](https://crates.io/crates/trusted-signing-cli) | the variables it reads; the old name deprecated |
| [Livebook's macOS entitlements](https://github.com/livebook-dev/livebook/blob/main/rel/app/src-tauri/App.entitlements) | what a desktop app bundling ERTS declares |
