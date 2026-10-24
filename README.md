# Elysium Infrastructure

Infrastructure as Code for **Elysium**, my personal cloud project on AWS. It's built with Terraform, and Terragrunt will join as the project grows. Security guardrails are part of the design from the very first commit.

> **Status: early stage.** The repository currently contains the bootstrap for the Terraform remote state, the first Terragrunt-managed environment (`dev`), the account's MFA-enforcement policy and the local tooling to open MFA-authenticated AWS CLI sessions. This README grows alongside the infrastructure.

---

## Table of contents

- [Repository structure](#repository-structure)
- [Prerequisites](#prerequisites)
- [Security model](#security-model)
  - [IAM identities](#iam-identities)
  - [Enforced MFA](#enforced-mfa)
  - [The console vs. CLI gotcha](#the-console-vs-cli-gotcha)
  - [Threat model: the MFA re-enrollment bypass](#threat-model-the-mfa-re-enrollment-bypass)
- [MFA session script](#mfa-session-script)
  - [What it does](#what-it-does)
  - [Setup](#setup)
  - [Usage](#usage)
  - [Safety details](#safety-details)
  - [Troubleshooting](#troubleshooting)
- [Terraform state bootstrap](#terraform-state-bootstrap)
- [Conventions](#conventions)
- [Roadmap](#roadmap)

---

## Repository structure

```text
elysium_infrastructure/
├── bootstrap/                 # One-time Terraform config that creates the remote state bucket
│   ├── main.tf                #   S3 bucket + public access block
│   ├── outputs.tf             #   Exposes the bucket name
│   ├── provider.tf            #   Terraform/provider version pins, region and default tags
│   └── .terraform.lock.hcl    #   Provider lock file (committed on purpose)
├── dev/                       # Terragrunt live configuration for the dev environment
│   ├── root.hcl               #   Remote state (S3 + native lockfile), provider and default tags
│   └── buckets/
│       └── elysium-app-assets/  # First bucket deployed with Terragrunt
├── modules/                   # Reusable Terraform modules
│   └── s3/
├── shared/                    # Account-wide resources, shared by every environment
│   └── iam/
│       └── policies/
│           └── enforce-mfa.json # MFA-enforcement policy (source of truth)
├── scripts/
│   └── aws-mfa-session.sh     # Opens an MFA-authenticated AWS CLI session in the current shell
├── .env.example               # Template for the MFA script configuration
├── .gitattributes             # Forces LF line endings (critical for shell scripts edited on Windows)
└── .gitignore                 # Keeps state files, *.tfvars and .env out of Git
```

---

## Prerequisites

| Tool | Version | Used for |
|---|---|---|
| [Terraform](https://developer.hashicorp.com/terraform/install) | `>= 1.10, < 2.0` | Provisioning infrastructure |
| [Terragrunt](https://terragrunt.gruntwork.io/docs/getting-started/install/) | Current release | Managing environments and remote state |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2 | Authentication and the MFA script |
| Bash | 4.0+ (Linux or WSL) | Running the MFA script (it uses `mapfile`) |
| Python | 3.x | Parsing the STS response inside the MFA script |
| Authenticator app | Any TOTP app | Generating the 6-digit MFA codes |

---

## Security model

### IAM identities

The AWS account is organized around separate identities with clearly scoped responsibilities:

| Identity | Purpose | Permissions |
|---|---|---|
| `root` | Account owner | Reserved for the few tasks only the root user can perform. Never used for day-to-day work. |
| `admin` | Full administration | AWS managed `AdministratorAccess` policy |
| `devops` | Day-to-day infrastructure operations | Scoped policy limited to the core DevOps tasks |
| *Future users* (e.g. developers) | Role-specific work | Only what each role needs |

### Enforced MFA

Every IAM group has the customer-managed policy **`EnforceMFAConfiguration`** attached. Its source of truth lives in [`shared/iam/policies/enforce-mfa.json`](shared/iam/policies/enforce-mfa.json).

**Onboarding flow:**

1. An admin creates the user with a console password only (**no access keys**) and adds it to the right group.
2. The new user signs in and finds everything blocked, except registering an MFA device on their own user.
3. After signing back in with MFA, the group's permissions apply as usual. Only now can the user change their password or create their own access keys.

**How the policy is built:**

| Statement | Effect | Purpose |
|---|---|---|
| `AllowViewAccountInfo` | Allow | Lets the console's MFA wizard read the password policy and list virtual devices |
| `AllowCreateVirtualMFADevice` | Allow | Lets users create a virtual MFA device |
| `AllowManageOwnMFAAndCredentials` | Allow | Self-service on **your own user only** (`${aws:username}`): MFA devices, password, access keys |
| `AllowTagOwnUserForAccessKeyDescriptions` | Allow | The console stores access-key descriptions as user tags. Only tag keys matching `AKIA*` are allowed, so users can't self-assign arbitrary tags. |
| `DenyAllIfNoMFA` | Deny | Denies **everything except** the MFA-setup actions and `sts:GetSessionToken` while MFA is absent |
| `DenyMFAEnrollmentWithAccessKeysOnly` | Deny | Blocks MFA enrollment from bare access keys (see [Threat model](#threat-model-the-mfa-re-enrollment-bypass)) |
| `DenyTouchingOtherUsersMFAWithoutMFA` | Deny | The no-MFA exceptions only ever apply to the caller's own user |

Three details make it work:

- **`Deny` + `NotAction`** means "deny everything *except* the listed actions". One statement covers every AWS service.
- **`BoolIfExists`** matches when `aws:MultiFactorAuthPresent` is `false` **or missing**. Requests signed with long-term access keys don't carry the key at all, so they're denied too.
- **An explicit `Deny` always beats an `Allow`.** Even `AdministratorAccess` is blocked until the user authenticates with MFA.

The Allow statements matter for groups with limited permissions, such as DevOps. A `Deny` never grants anything, so without them a new user in that group couldn't even enroll MFA.

### The console vs. CLI gotcha

This is where things got interesting. The policy worked exactly as intended in the **web console**: sign in with password + MFA code, and everything assigned to the user is available.

From the terminal, though, even a simple call failed:

```console
$ aws s3 ls --profile devops
An error occurred (AccessDenied) when calling the ListBuckets operation: ...
```

**Why?** The AWS CLI signs requests with the user's **long-term access keys**. Those keys carry no MFA context, so `aws:MultiFactorAuthPresent` is missing from the request, and the MFA policy denies it. The access keys are valid. The request just isn't MFA-authenticated.

**The fix** is to trade the long-term keys plus a current MFA code for **temporary credentials** through AWS STS (`GetSessionToken`). Credentials issued this way *do* carry the MFA context, so the policy lets them through. Doing that by hand every time is tedious, so it's automated in [`scripts/aws-mfa-session.sh`](scripts/aws-mfa-session.sh).

```mermaid
sequenceDiagram
    actor You
    participant Script as aws-mfa-session.sh
    participant STS as AWS STS
    participant AWS as AWS services

    You->>Script: source scripts/aws-mfa-session.sh
    Script->>You: Enter your MFA code
    You->>Script: 6-digit code from authenticator app
    Script->>STS: GetSessionToken (base profile + MFA serial + code)
    STS-->>Script: Temporary AccessKeyId / SecretAccessKey / SessionToken
    Script->>Script: Validate and export credentials to the shell
    Script->>STS: GetCallerIdentity (sanity check)
    STS-->>You: Identity confirmed, session ready
    You->>AWS: aws ... / terraform ... (MFA-authenticated)
```

### Threat model: the MFA re-enrollment bypass

The first version of the policy only had `DenyAllIfNoMFA`. It protected the **password** well, but not the **access keys**. Its exceptions didn't care *how* a request was signed, so anyone holding a leaked key could:

1. `iam:CreateVirtualMFADevice`: create their own virtual MFA device (an exception, so allowed without MFA).
2. `iam:EnableMFADevice`: attach it to the victim's user. IAM allows up to 8 devices per user, so the legitimate one keeps working and nothing looks wrong.
3. `sts:GetSessionToken` with *their* device: receive a fully MFA-authenticated session.

**The fix** is `DenyMFAEnrollmentWithAccessKeysOnly`, which uses a `Null` condition:

```json
"Condition": { "Null": { "aws:MultiFactorAuthPresent": "true" } }
```

The key is **missing** only on requests signed with long-term access keys. A console session always carries it (as `false` before MFA), so new users can still enroll from the browser, while bare keys cannot.

The next obvious trick, calling `sts:GetSessionToken` *without* an MFA code and using those credentials to enroll, doesn't work either. AWS rejects IAM API calls made with session-token credentials that were obtained without MFA.

**Verification** (run against a real DevOps user before rolling the policy out):

| # | Test | Result |
|---|---|---|
| 1 | Console sign-in before MFA, then register MFA | Everything blocked except MFA setup. Enrollment works. |
| 2 | Create an access key with a description after MFA | Works |
| 3 | `aws s3 ls` with bare access keys | `AccessDenied`, explicit deny |
| 4 | `aws iam create-virtual-mfa-device …` with bare access keys | `AccessDenied`, **bypass closed** |
| 5 | `source scripts/aws-mfa-session.sh`, then `aws s3 ls` | Works |

---

## MFA session script

### What it does

`scripts/aws-mfa-session.sh` turns your long-term CLI profile into an MFA-authenticated session in a single command:

1. **Loads the configuration** from `.env` at the repository root.
2. **Validates the configuration:** the profile and MFA serial must be set, and the session duration must be an integer between 900 and 129600 seconds.
3. **Checks dependencies:** `aws` and `python3` must be on the `PATH`.
4. **Prompts for the MFA code** without echoing it, and checks it's exactly six digits.
5. **Requests temporary credentials** with `aws sts get-session-token` using your base profile.
6. **Parses and validates** the STS response, making sure every credential field is present and non-empty.
7. **Exports** `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN` into your current shell.
8. **Verifies the session** with `aws sts get-caller-identity`. If that fails, it removes the exported credentials again.

### Setup

**1. Configure your base CLI profile** (one time) with the IAM user's access keys:

```bash
aws configure --profile <your-profile-name>
```

**2. Create your local configuration** from the template:

```bash
cp .env.example .env
```

```dotenv
AWS_PROFILE_NAME=your_aws_cli_profile
MFA_SERIAL=arn:aws:iam::YOUR_ACCOUNT_ID:mfa/YOUR_MFA_DEVICE_NAME
SESSION_DURATION=3600
```

| Variable | Description |
|---|---|
| `AWS_PROFILE_NAME` | The CLI profile holding your long-term access keys (from step 1). |
| `MFA_SERIAL` | ARN of your MFA device. Find it in **IAM → Users → *your user* → Security credentials → Multi-factor authentication (MFA)**. |
| `SESSION_DURATION` | Lifetime of the temporary credentials, in seconds. Allowed range: `900`–`129600` (15 min to 36 h). Default: `3600` (1 h). |

> `.env` is gitignored. Only `.env.example` is tracked.

### Usage

The script must be **sourced**, not executed:

```bash
source scripts/aws-mfa-session.sh
```

```console
Enter your MFA code:
Temporary AWS credentials exported.
Session expiration: 2026-10-16T19:30:00+00:00
Verifying AWS identity...
{
    "UserId": "AIDAXXXXXXXXXXXXXXXXX",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/devops"
}
AWS MFA session is ready.
```

From then on, everything in that terminal runs MFA-authenticated:

```bash
aws s3 ls
terraform plan    # the Terraform AWS provider picks up the exported variables automatically
```

**Why `source`?** A script run with `./script.sh` or `bash script.sh` runs in a child process. Any variables it exports disappear as soon as it exits. Sourcing runs it in *your* shell, so the credentials stay available. The script detects when it's executed instead of sourced and stops with a hint.

**Good to know:**

- The session applies **only to the terminal where you sourced the script**. A new terminal needs a new session.
- When the session expires, run the script again.
- To end the session early:

  ```bash
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  ```

### Safety details

- **The MFA code is never echoed** (`read -s`), and it's removed from memory right after the STS call.
- **The STS request is always signed with the base profile.** Any `AWS_*` credentials already in the shell are stripped from the subprocess. A leftover temporary session can never be used to request the new one.
- **Nothing partial is exported.** The STS response is parsed and validated in one step, and credentials reach the shell only if all four fields are present.
- **The identity check rolls back.** If `get-caller-identity` fails, the exported credentials are unset again.
- **Intermediate variables are cleaned up.** The raw STS response and parsed values are unset once they're no longer needed.

### Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Error: source this script, instead of executing it.` | Ran with `./` or `bash` | Use `source scripts/aws-mfa-session.sh` |
| `Error: configuration file is missing or unreadable` | No `.env` at the repo root | `cp .env.example .env` and fill it in |
| `SESSION_DURATION must be a positive integer` even though the value looks right | `.env` was saved with Windows (CRLF) line endings | `sed -i 's/\r$//' .env` |
| `$'\r': command not found` | The script itself has CRLF line endings | `sed -i 's/\r$//' scripts/aws-mfa-session.sh` (`.gitattributes` prevents this for checked-out files) |
| `Error: unable to obtain temporary AWS credentials.` | Wrong or expired code (codes rotate every 30 s), wrong `MFA_SERIAL`, or a bad base profile | Retry with a fresh code and double-check `.env` |
| Same error as above, every time, on WSL | WSL's clock drifted (common after the laptop sleeps), so the TOTP code doesn't match | Run `wsl --shutdown` from Windows, or `sudo hwclock -s` inside WSL |
| `mapfile: command not found` | Bash older than 4 (e.g. the default Bash on macOS) | Install a newer Bash, or use Linux/WSL |
| `AccessDenied` *after* "AWS MFA session is ready." | MFA works. The user simply lacks permission for that action | Review the policies attached to that IAM user |
| `ExpiredToken` | The session ran out | Source the script again |

---

## Terraform state bootstrap

Terraform keeps its state in an S3 bucket, but that bucket has to exist before any remote state can use it. The `bootstrap/` configuration solves this chicken-and-egg problem. It's a tiny Terraform config that runs **once**, with **local** state, and creates the bucket.

**What it creates:**

- An S3 bucket named `elysium-terraform-state-<account-id>`. The account ID suffix keeps the name globally unique.
- A public access block with all four settings enabled. The state bucket can never become public.
- Default tags (`Created`, `Environment`, `Project`, `Owner`) on every resource.

**Run it:**

```bash
source scripts/aws-mfa-session.sh
cd bootstrap
terraform init
terraform plan
terraform apply
```

**Notes:**

- The bootstrap's own `terraform.tfstate` stays **local and is gitignored**. Keep a safe copy of it.
- `.terraform.lock.hcl` **is committed**, so every machine uses the same provider versions.
- Versions are pinned in `provider.tf`: Terraform `>= 1.10.0, < 2.0.0` and AWS provider `~> 6.0`.

---

## Conventions

- **Region:** `us-east-1`
- **Tagging:** every resource gets `Created`, `Environment`, `Project` and `Owner` through the provider's `default_tags`.
- **Line endings:** LF everywhere, enforced by `.gitattributes`.
- **Never committed:** Terraform state, `*.tfvars` files and `.env` files.

---

## Roadmap

- [x] Remote state bucket bootstrap
- [x] MFA-authenticated CLI sessions
- [ ] Enable versioning on the state bucket
- [x] MFA-enforcement policy hardened against the re-enrollment bypass
- [x] State locking with the S3 native lockfile (`use_lockfile = true`)
- [x] First Terragrunt-managed environment (`dev`) with remote state
- [ ] Manage IAM users, groups and the MFA-enforcement policy as code (the policy JSON is already versioned)
- [ ] `prod` environment and shared resources
- [ ] CI checks on pull requests (`fmt`, `validate`, `plan`)
