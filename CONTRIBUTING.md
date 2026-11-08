# Contributing

Thanks for helping improve this project! Contributions of every size are welcome: typo fixes, clearer
documentation, bug reports, tests or new features.

## Ground rules

- **English only** for code, comments, documentation, commits, issues and pull requests.
- **Small, focused pull requests.** One topic per pull request; split large changes.
- **Tests come with the change.** New behaviour is covered by tests and bug fixes include a regression test.
- **Never commit secrets** or personal data. Use `.env.example` for configuration templates.

## Development setup

<!-- Replace with the real prerequisites and commands of the project. -->

| Toolchain | Version |
| --- | --- |
| _e.g. Node.js_ | _22+_ |

```bash
# Install dependencies, then run every check before opening a pull request.
# e.g.: npm ci && npm run lint && npm test && npm run build
```

Repository-wide checks run in CI on every pull request:

| Check | What it verifies |
| --- | --- |
| `markdown` | Markdown style ([`.markdownlint.jsonc`](.markdownlint.jsonc)) |
| `editorconfig` | Encoding, line endings, indentation and trailing whitespace ([`.editorconfig`](.editorconfig)) |
| `actionlint` | GitHub Actions workflow syntax and shell scripts |
| `conventional-commits` | Pull request title format |
| CodeQL, dependency review | Security analysis and vulnerable dependencies |

## Commit messages and pull request titles

This repository follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
Releases, version numbers and `CHANGELOG.md` are generated from them, and CI rejects pull request titles
that don't comply.

```text
<type>(<optional scope>): <lowercase description>

feat(api): add pagination to the orders endpoint
fix(auth): refresh expired tokens before retrying
docs: explain how to run the project locally
```

| Type | Use it for | Release impact |
| --- | --- | --- |
| `feat` | a new feature | minor |
| `fix` | a bug fix | patch |
| `docs` | documentation only | none |
| `test`, `refactor`, `perf`, `style` | code changes without new behaviour | none |
| `build`, `ci`, `chore` | tooling, dependencies, pipelines | none |
| `revert` | reverting a previous commit | depends on the reverted commit |

Add `!` after the type (`feat!:`) and a `BREAKING CHANGE:` footer for breaking changes (major release).
Write a body that explains **what** changed and **why**, wrapped at 72 characters.

## Branches

Branch from `main` using the commit type as prefix: `feat/<topic>`, `fix/<topic>`, `docs/<topic>`,
`chore/<topic>`, `ci/<topic>`.

## Pull request process

Nobody pushes to `main` directly, maintainers included: every change arrives through a pull request.

1. **Fork** the repository (or create a branch if you are a maintainer) from `main`.
2. Make your change with tests and run the checks above.
3. Open a pull request using the template. Its title must be a Conventional Commit. Pick a specific
   template when it fits: `feature.md`, `bugfix.md`, `documentation.md`, `maintenance.md` or `security.md`
   (`gh pr create --template feature.md`, or add `?template=feature.md` to the compare URL).
4. **Workflow approval.** For security, GitHub Actions do not run on pull requests from outside
   contributors until a maintainer approves them. Expect a short wait before CI starts.
5. **Merge requirements** on `main`:
   - Every required check is green, with no high-severity code scanning alerts.
   - A code owner has approved the latest changes and every review conversation is resolved.
   - **Commits are signed** ([how to sign commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits)).
     Maintainers can sign an existing branch without squashing it with
     [`scripts/fix-repo.ps1`](scripts/fix-repo.ps1).
   - Pull requests are merged with a merge commit or squashed (no rebase merges); the branch is deleted
     after merging.

## Releases

[release-please](https://github.com/googleapis/release-please) keeps a release pull request open with the
next [Semantic Versioning](https://semver.org/) number and the changelog. Merging it creates the `vX.Y.Z`
tag and the GitHub Release. Release tags are protected and can never be moved or deleted.

## Code of Conduct

By participating you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
