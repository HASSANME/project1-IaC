Notes of 21/08/2026:

"""

# Terraform + AWS + GitHub Actions — Combined Study Notes

## 1. Problems We Solved

- GitHub Actions couldn't authenticate to AWS — error: `Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity`
- Terraform init/plan/apply failed because credentials never arrived
- Terraform initialized in an empty directory (config files were in a subfolder, not repo root)
- A strict validator complained about a missing `Resource` field in the trust policy
- Stuck/runaway workflow runs needed to be cancelled

## 2. Root Causes

**OIDC / trust policy problems (the recurring theme across sessions):**

- Trust policy was missing or misconfigured, so AWS never authorized GitHub's OIDC provider to assume the role
- `StringEquals` was used with a `*` wildcard in the `sub` condition — `StringEquals` does not treat `*` as a wildcard, so it silently failed to match; `StringLike` is needed for pattern matching
- Repo used the newer immutable `sub` format (owner/repo IDs), which didn't match the older `repo:owner/repo:*` string the policy expected
- ⚠️ **Conflicting note across sources:** one troubleshooting session identified the root cause as a **thumbprint mismatch** between AWS's stored certificate fingerprint and GitHub's actual current certificate. Another session traced the same symptom to the **trust policy `sub`/`StringEquals` issue** above, with thumbprint ruled out as secondary. Both are real, valid OIDC failure modes — but they're different bugs. When you hit this error again, check both instead of assuming which one it is from memory.
- Missing `permissions: { id-token: write, contents: read }` block at the top of the workflow — without this, GitHub can't generate an OIDC token at all

**Terraform directory problem:**

- GitHub Actions runs from the repo root by default; `terraform init` only looks in its current directory, so it saw "empty directory" when the `.tf` files lived in a subfolder, it was solved using "working-directory: ./terraform"

**Validator / schema problem:**

- IAM trust policies don't normally need a `Resource` field , but IAM permission policy need it


## 3. Fixes Applied

### Delete and recreate the OIDC provider (if thumbprint is suspected)

```bash
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"

aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "<CURRENT_THUMBPRINT>"
```

### Fix the trust policy (StringLike + Resource field + flexible sub)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:<OWNER>/<REPO>:*",
            "repo:<OWNER>@*/<REPO>@*:*"
          ]
        }
      }
    }
  ]
}
```

Notes on this policy:
- `Resource: "*"` is added only to satisfy strict validators — functionally trust policies don't need it, but it's harmless here
- Use `StringLike` (not `StringEquals`) whenever the `sub` condition contains a wildcard
- Include both the classic and immutable `sub` formats if you're not sure which one your repo emits
- Lock `sub` down to an exact branch with `StringEquals` only if you don't need wildcards at all

### Add a permissions policy (separate from trust policy)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:*",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

### Fix the workflow YAML

```yaml
permissions:
  id-token: write   # required to generate an OIDC token
  contents: read

jobs:
  terraform:
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-region: ${{ secrets.AWS_REGION }}
          role-to-assume: ${{ secrets.ROLE_TO_ASSUME }}

      - name: Verify identity before touching Terraform
        run: aws sts get-caller-identity

      - name: Terraform Init
        working-directory: ./terraform    # fixes the "empty directory" error
        run: terraform init
```

Or set the working directory once for the whole job:

```yaml
defaults:
  run:
    working-directory: ./terraform
```

### Clean up stuck workflows and dead runners

```bash
# Remove a live self-hosted runner cleanly
sudo ./svc.sh uninstall
./config.sh remove --token <TOKEN>   # token expires fast — generate right before running this
```

- Dead/offline runners with no host left: use **Force remove this runner** in the GitHub repo/org settings UI
- Stuck or runaway workflow runs: cancel from the Actions tab UI; delete history via the `...` menu

### Stop duplicate runs with concurrency control

```yaml
concurrency:
  group: terraform-${{ github.ref }}
  cancel-in-progress: true
```

⚠️ Give each workflow a distinct `group` name — if two different workflows share the exact same group string, they'll cancel each other instead of just their own duplicates.

## 4. Key Concepts to Remember

- **Trust Policy vs. Permissions Policy** — this distinction is the single most important thing across every session:
  - **Trust policy** = *who* can assume the role (GitHub's OIDC provider, under what conditions)
  - **Permissions policy** = *what* the role can do once assumed (S3, EC2, etc.)
  - An `AssumeRoleWithWebIdentity` error → look at the trust policy. An `s3:...` or similar permission error → look at the permissions policy.
- **OIDC (OpenID Connect)** lets GitHub Actions trade a short-lived token with AWS instead of storing long-lived AWS access keys as secrets
- **Token claims:**
  - `aud` (audience) — who the token is for, normally `sts.amazonaws.com`
  - `sub` (subject) — which repo/branch/workflow the token came from
- **`StringEquals` vs. `StringLike`** — `StringEquals` is an exact match only; `*` inside it is treated literally, not as a wildcard. Use `StringLike` for pattern matching.
- **`permissions: id-token: write`** at the top of the workflow file is required before GitHub can even generate an OIDC token — this is a separate requirement from the AWS-side trust policy
- **Case sensitivity** — GitHub org/repo names are case-sensitive in AWS trust policy conditions
- **Terraform working directory** — `terraform init/plan/apply` only look at `.tf` files in their current directory; GitHub Actions starts in the repo root unless told otherwise

## 5. Things to Watch Out For Next Time

- ❌ Don't assume `*` works as a wildcard inside `StringEquals` — it doesn't; use `StringLike`
- ❌ Don't forget `permissions: { id-token: write, contents: read }` in the workflow — without it, no OIDC token is generated at all
- ❌ Don't leave workflow jobs inconsistent — if multiple jobs talk to AWS, they all need the same credentials config
- ❌ Don't hardcode an OIDC thumbprint from old notes — regenerate it from GitHub directly, since it can change
- ❌ Don't confuse trust policy problems with permissions policy problems — check `sts:AssumeRoleWithWebIdentity` errors against the trust policy first, not by broadening permissions
- ❌ Don't restrict `sub` to one exact branch with `StringEquals` unless you actually want that; use `StringLike` with a wildcard for flexibility across branches/PRs
- ❌ Don't forget case sensitivity in repo/org names inside trust policy conditions
- ❌ Don't let concurrency groups collide across different workflows — name them uniquely
- ✅ Verify AWS identity first with `aws sts get-caller-identity` before running any Terraform commands, to isolate OIDC issues from Terraform issues
- ✅ Check AWS CloudTrail logs when OIDC fails — they show the exact reason AWS rejected the token

"""