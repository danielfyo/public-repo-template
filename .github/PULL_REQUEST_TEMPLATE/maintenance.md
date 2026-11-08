## Maintenance

<!-- Title: build|ci|chore|refactor|perf|test(<scope>): <lowercase description>. -->

### Type

- [ ] `build`: dependencies or build system
- [ ] `ci`: GitHub Actions workflows
- [ ] `chore`: tooling and repository housekeeping
- [ ] `refactor` / `perf` / `test`: code changes without new behaviour

### What and why

<!-- What changed and why it is needed. -->

### Impact

<!-- Behaviour must not change. Note risks, new required checks or settings to update
     (for example, re-running scripts/setup-repo.ps1 for new required checks or allowed actions). -->

### Checklist

- [ ] The title follows [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
- [ ] New or updated GitHub Actions are pinned to a full commit SHA with a version comment, use
      least-privilege `permissions` and `persist-credentials: false`.
- [ ] Every check passes locally and in CI.
- [ ] No secrets, credentials or personal data are included.
- [ ] Commits are signed.
