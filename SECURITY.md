# Security Policy

## Supported versions

Only the latest release on `main` receives security fixes.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Use GitHub's private reporting instead: go to the **Security** tab of this repository and choose
**Report a vulnerability**. You will receive an answer within 7 days, and a fix or mitigation plan as
soon as the issue is confirmed. Coordinated disclosure is appreciated: give us a reasonable time to
publish a fix before disclosing the issue publicly.

Examples of what to report:

- Code that is vulnerable (injection, secrets in code, unsafe deserialisation, broken access control…).
- A vulnerable dependency that Dependabot has not flagged.
- A weakness in the GitHub Actions workflows (for example, script injection or excessive permissions).

## How the repository is protected

- **Protected `main`:** changes only through pull requests with green checks, code-owner approval,
  resolved conversations and signed commits; force pushes and deletion are blocked.
- **Protected release tags:** `v*` tags can never be moved or deleted.
- **Pull requests from forks:** workflows from outside contributors need a maintainer's approval before
  they run, and the workflow token is read-only by default.
- **Supply chain:** every GitHub Action is pinned to a full commit SHA, checkouts don't persist
  credentials, dependency review blocks vulnerable dependencies in pull requests, and
  [OpenSSF Scorecard](https://scorecard.dev/) grades these practices weekly.

## Automated checks

- **CodeQL** scans every pull request, `main`, and the whole repository weekly.
- **Secret scanning** with push protection blocks commits that contain credentials.
- **Dependabot** alerts on vulnerable dependencies and opens weekly update pull requests.
