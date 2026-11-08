# public-repo-template

[![CI](https://github.com/danielfyo/public-repo-template/actions/workflows/ci.yml/badge.svg)](https://github.com/danielfyo/public-repo-template/actions/workflows/ci.yml)
[![CodeQL](https://github.com/danielfyo/public-repo-template/actions/workflows/codeql.yml/badge.svg)](https://github.com/danielfyo/public-repo-template/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/danielfyo/public-repo-template/badge)](https://scorecard.dev/viewer/?uri=github.com/danielfyo/public-repo-template)
[![Latest release](https://img.shields.io/github/v/release/danielfyo/public-repo-template?sort=semver)](https://github.com/danielfyo/public-repo-template/releases)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-fe5196.svg?logo=conventionalcommits&logoColor=white)](https://www.conventionalcommits.org/en/v1.0.0/)

> **A secure, ready-to-ship starting point for public repositories.** Licence, community health files,
> Conventional Commits, automated releases, supply-chain hardening and branch protection, configured
> from the first commit.

## 🚀 Using this template

1. Click **Use this template → Create a new repository** on GitHub (or
   `gh repo create <owner>/<name> --public --template danielfyo/public-repo-template`).
2. Replace `public-repo-template` with the new repository name everywhere:

   ```bash
   git grep -l public-repo-template | xargs sed -i 's/public-repo-template/<name>/g'
   ```

3. Run the setup script once, as a repository admin, to apply the settings that can't live in files
   (description, topics, labels, security features, merge options and rulesets):

   ```powershell
   ./scripts/setup-repo.ps1 -Owner <owner> -Repo <name>
   ```

4. Adapt the project-specific parts:
   - [ ] Rewrite this README (keep the badges and the sections below that still apply).
   - [ ] Add the project's build/test jobs to [`ci.yml`](.github/workflows/ci.yml) and their job ids to
         the required checks in [`setup-repo.ps1`](scripts/setup-repo.ps1); re-run the script.
   - [ ] Add the project's languages to [`codeql.yml`](.github/workflows/codeql.yml).
   - [ ] Add the project's package ecosystems to [`dependabot.yml`](.github/dependabot.yml).
   - [ ] Fill in prerequisites and commands in [`CONTRIBUTING.md`](CONTRIBUTING.md).
   - [ ] Set `package-name` in [`release-please-config.json`](release-please-config.json).
   - [ ] Review [`CODEOWNERS`](.github/CODEOWNERS) and the licence holder in [`LICENSE`](LICENSE).
   - [ ] Upload a social preview image (Settings → General → Social preview, 1280×640).

## 📦 What's included

| Area | Files | What you get |
| --- | --- | --- |
| Licence | [`LICENSE`](LICENSE) | MIT |
| Community health | [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md), [`CONTRIBUTING.md`](CONTRIBUTING.md), [`SECURITY.md`](SECURITY.md), [`SUPPORT.md`](SUPPORT.md) | Contributor Covenant 2.1, contribution rules, private vulnerability reporting |
| Issues and PRs | [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE), [`pull_request_template.md`](.github/pull_request_template.md), [`CODEOWNERS`](.github/CODEOWNERS) | Issue forms (bug, feature), PR checklist, automatic reviewers |
| Consistency | [`.editorconfig`](.editorconfig), [`.gitattributes`](.gitattributes), [`.gitignore`](.gitignore), [`.markdownlint.jsonc`](.markdownlint.jsonc) | UTF-8 + LF everywhere, per-language indentation, ignores for every common stack and for secrets |
| CI | [`ci.yml`](.github/workflows/ci.yml) | Markdown, EditorConfig and workflow linting; slot for project jobs |
| Commits | [`pr-title.yml`](.github/workflows/pr-title.yml) | Conventional Commits enforced on PR titles |
| Releases | [`release-please.yml`](.github/workflows/release-please.yml), [`release-please-config.json`](release-please-config.json), [`CHANGELOG.md`](CHANGELOG.md) | SemVer tags, GitHub Releases and changelog generated from commits |
| Security | [`codeql.yml`](.github/workflows/codeql.yml), [`dependency-review.yml`](.github/workflows/dependency-review.yml), [`scorecard.yml`](.github/workflows/scorecard.yml), [`dependabot.yml`](.github/dependabot.yml) | Static analysis, vulnerable-dependency gate, OpenSSF Scorecard, weekly updates |
| Settings | [`scripts/setup-repo.ps1`](scripts/setup-repo.ps1) | Repository settings, labels and rulesets as code |
| Signed history | [`scripts/fix-repo.ps1`](scripts/fix-repo.ps1) | Re-signs a branch's commits so they are Verified, without squashing |

## ✍️ Verified commits without squashing

`main` only accepts signed commits. When a branch has unsigned commits (for example, because the local git
identity belongs to another organization), re-create them through the GitHub API, which signs them, and
keep the full history:

```powershell
# Preview, then run. Requires PowerShell 5.1+ and installs the GitHub CLI if it is missing.
./scripts/fix-repo.ps1 -Owner <owner> -Repo <repo> -Branch <branch> -WhatIf
./scripts/fix-repo.ps1 -Owner <owner> -Repo <repo> -Branch <branch>
```

The script replays every commit (same order, messages and files) with GitHub's `createCommitOnBranch`,
checks that the final file tree is identical, and only then moves the branch. Open pull requests update
automatically; merge them with a **merge commit** so each Verified commit reaches `main`:

```bash
gh pr merge <number> --merge --subject "<type>(<scope>): <description> (#<number>)" --delete-branch
```

## 🛡️ Standards

- **English only** in code, comments, docs, commits and pull requests.
- **Conventional Commits** for every commit and pull request title; releases follow
  [Semantic Versioning](https://semver.org/).
- **Protected `main`:** pull requests only, required checks, code-owner approval, resolved conversations,
  signed commits, merge commit or squash (no rebase merges), no force pushes or
  deletion.
- **Protected release tags:** `v*` tags can't be moved or deleted.
- **Least-privilege workflows:** read-only token by default, explicit per-job permissions, every action
  pinned to a full commit SHA, checkouts without persisted credentials.
- **Secrets never in Git:** secret scanning with push protection, `.env` files ignored.

## 🤝 Contributing

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before opening a pull request, and report vulnerabilities
privately as described in [`SECURITY.md`](SECURITY.md).

## 📄 License

[MIT](LICENSE) © Daniel F Yepes O
