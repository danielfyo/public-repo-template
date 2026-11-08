#Requires -Version 5.1
<#
.SYNOPSIS
    Applies the GitHub settings that cannot live in files: About, topics, labels, merge options,
    security features, Actions hardening and the rulesets that protect main and the release tags.

    Result: nobody (maintainer included) can change main without a pull request; anyone can
    fork and open pull requests, but their workflows only run after a maintainer approves them.

.DESCRIPTION
    Uses only the GitHub CLI (gh). Safe to run more than once: every step checks or overwrites
    the current state. Run it once after creating a repository from the template, and again
    whenever the required checks, the allow-listed actions or the topics change.

    Works on Windows PowerShell 5.1 and PowerShell 7+.

.PARAMETER Owner
    Repository owner (user or organization).

.PARAMETER Repo
    Repository name.

.PARAMETER Description
    The "About" text of the repository.

.PARAMETER Topics
    Repository topics (GitHub allows at most 20).

.PARAMETER RequiredChecks
    Job names that must be green before merging to main. Keep the template's checks and add
    the project's own CI jobs.

.PARAMETER AllowedActions
    Third-party actions allowed to run (GitHub-owned actions are always allowed). Every action
    used in .github/workflows must be listed here.

.PARAMETER Template
    Marks the repository as a template repository.

.EXAMPLE
    ./scripts/setup-repo.ps1 -Owner <owner> -Repo <repo> -WhatIf     # preview
    ./scripts/setup-repo.ps1 -Owner <owner> -Repo <repo> -Description 'What the project does.' -Topics 'dotnet','api'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string] $Owner,
    [Parameter(Mandatory)][string] $Repo,
    [string] $Description,
    [string[]] $Topics = @(),
    [string] $Homepage,
    [string[]] $RequiredChecks = @('markdown', 'editorconfig', 'actionlint', 'conventional-commits', 'dependency-review'),
    [string[]] $AllowedActions = @(
        'amannn/action-semantic-pull-request@*',
        'googleapis/release-please-action@*',
        'ossf/scorecard-action@*',
        'DavidAnson/markdownlint-cli2-action@*',
        'editorconfig-checker/action-editorconfig-checker@*',
        'raven-actions/actionlint@*'
    ),
    [switch] $Template
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue   # 5.1 ConvertTo-Json array fix
}

$FullName = "$Owner/$Repo"
$RepoPath = "repos/$FullName"

function Invoke-Gh {
    <# Runs gh, returns stdout lines, throws with gh's error output on failure. #>
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFailure)
    $ErrorActionPreference = 'Continue'
    $WhatIfPreference = $false
    $previousEncoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { }
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & gh @Arguments 2> $errorFile
        if ($LASTEXITCODE -ne 0) {
            # gh prints the API's error body (with the validation details) on stdout.
            $details = ([System.IO.File]::ReadAllText($errorFile) + "`n" + ($output -join "`n")).Trim()
            if ($AllowFailure) { Write-Warning "gh $($Arguments -join ' ') failed: $details"; return $null }
            throw "gh $($Arguments -join ' ') failed (exit $LASTEXITCODE):`n$details"
        }
        return $output
    }
    finally {
        [System.IO.File]::Delete($errorFile)
        try { [Console]::OutputEncoding = $previousEncoding } catch { }
    }
}

function Test-Gh {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $ErrorActionPreference = 'Continue'
    $WhatIfPreference = $false
    & gh @Arguments *> $null
    return $LASTEXITCODE -eq 0
}

function Invoke-GhWithJsonBody {
    <# Sends a JSON body from a temp file (avoids quoting problems on the command line). #>
    param([Parameter(Mandatory)][string] $Method, [Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Body, [switch] $AllowFailure)
    $file = [System.IO.Path]::GetTempFileName()
    try {
        $json = $Body | ConvertTo-Json -Depth 20
        [System.IO.File]::WriteAllText($file, $json, [System.Text.UTF8Encoding]::new($false))
        $result = Invoke-Gh @('api', '-X', $Method, $Path, '--input', $file) -AllowFailure:$AllowFailure
        if ($AllowFailure -and $null -eq $result -and $LASTEXITCODE -ne 0) { return $null }
        if ($null -eq $result) { return '' }
        return $result
    }
    finally { [System.IO.File]::Delete($file) }
}

function Write-Step([string] $Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw "GitHub CLI (gh) is not installed: winget install --id GitHub.cli --exact" }
if (-not (Test-Gh @('auth', 'status', '--hostname', 'github.com'))) { throw "gh is not logged in. Run: gh auth login" }

# ----------------------------------------------------------------------------- 1. About and merge options
Write-Step 'About, topics and merge options'
if ($Topics.Count -gt 20) { throw "GitHub allows at most 20 topics; got $($Topics.Count)." }
if ($PSCmdlet.ShouldProcess($FullName, 'Set description, homepage, topics and merge options')) {
    $editArguments = @('repo', 'edit', $FullName,
        '--enable-merge-commit', '--enable-squash-merge', '--enable-rebase-merge=false',
        '--delete-branch-on-merge', '--allow-update-branch',
        '--enable-wiki=false', '--enable-projects=false', '--enable-issues')
    if ($Description) { $editArguments += @('--description', $Description) }
    if ($Homepage) { $editArguments += @('--homepage', $Homepage) }
    if ($Topics.Count -gt 0) { $editArguments += @('--add-topic', ($Topics -join ',')) }
    if ($Template) { $editArguments += '--template' }
    Invoke-Gh $editArguments | Out-Null
    Write-Host '  Done.'
}

# ----------------------------------------------------------------------------- 1b. Labels
Write-Step 'Labels'
# Used by the issue forms, Dependabot and release-please. --force updates existing labels.
$labels = @(
    @{ Name = 'bug'; Color = 'd73a4a'; Description = 'Something does not work as documented' }
    @{ Name = 'enhancement'; Color = 'a2eeef'; Description = 'New feature or improvement' }
    @{ Name = 'documentation'; Color = '0075ca'; Description = 'Documentation only' }
    @{ Name = 'dependencies'; Color = '0366d6'; Description = 'Dependency updates' }
    @{ Name = 'github_actions'; Color = '000000'; Description = 'GitHub Actions workflows and their updates' }
    @{ Name = 'security'; Color = 'b60205'; Description = 'Security fix or hardening' }
    @{ Name = 'breaking-change'; Color = 'e99695'; Description = 'Introduces a breaking change (major release)' }
    @{ Name = 'good first issue'; Color = '7057ff'; Description = 'Good for newcomers' }
    @{ Name = 'help wanted'; Color = '008672'; Description = 'Extra attention is needed' }
    @{ Name = 'autorelease: pending'; Color = 'ededed'; Description = 'Release pull request not yet released (release-please)' }
    @{ Name = 'autorelease: tagged'; Color = 'ededed'; Description = 'Release pull request already tagged (release-please)' }
)
if ($PSCmdlet.ShouldProcess($FullName, "Create or update $($labels.Count) labels")) {
    foreach ($label in $labels) {
        Invoke-Gh @('label', 'create', $label.Name, '--repo', $FullName, '--color', $label.Color, '--description', $label.Description, '--force') | Out-Null
    }
    Write-Host '  Done.'
}

# ----------------------------------------------------------------------------- 2. Security features
Write-Step 'Security features'
if ($PSCmdlet.ShouldProcess($FullName, 'Enable Dependabot alerts and security updates, private vulnerability reporting, secret scanning')) {
    Invoke-Gh @('api', '-X', 'PUT', "$RepoPath/vulnerability-alerts") -AllowFailure | Out-Null
    Invoke-Gh @('api', '-X', 'PUT', "$RepoPath/automated-security-fixes") -AllowFailure | Out-Null
    Invoke-Gh @('api', '-X', 'PUT', "$RepoPath/private-vulnerability-reporting") -AllowFailure | Out-Null
    Invoke-GhWithJsonBody -Method PATCH -Path $RepoPath -Body @{
        security_and_analysis = @{
            secret_scanning                 = @{ status = 'enabled' }
            secret_scanning_push_protection = @{ status = 'enabled' }
        }
    } | Out-Null
    Write-Host '  Done.'
}

# ----------------------------------------------------------------------------- 3. Actions hardening
Write-Step 'GitHub Actions hardening'
if ($PSCmdlet.ShouldProcess($FullName, 'Read-only GITHUB_TOKEN, allow-listed and SHA-pinned actions, approval for fork workflows')) {
    # Read-only token by default. 'can_approve_pull_request_reviews' is GitHub's single switch for
    # "Allow GitHub Actions to create and approve pull requests": release-please needs it to open release
    # PRs. An approval from Actions never satisfies the code-owner review that main requires.
    Invoke-Gh @('api', '-X', 'PUT', "$RepoPath/actions/permissions/workflow",
        '-f', 'default_workflow_permissions=read', '-F', 'can_approve_pull_request_reviews=true') | Out-Null

    # Only GitHub-owned actions plus an explicit allow-list, and (where supported) only full-SHA references.
    $actionsPolicy = Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/actions/permissions" -AllowFailure -Body @{
        enabled = $true; allowed_actions = 'selected'; sha_pinning_required = $true
    }
    if ($null -eq $actionsPolicy) {
        Write-Host '  SHA pinning policy not available for this account; applying the allow-list only.'
        Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/actions/permissions" -Body @{ enabled = $true; allowed_actions = 'selected' } | Out-Null
    }
    Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/actions/permissions/selected-actions" -Body @{
        github_owned_allowed = $true
        verified_allowed     = $false
        patterns_allowed     = @($AllowedActions)
    } | Out-Null

    # Workflows triggered by pull requests from forks of outside contributors wait for approval.
    Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/actions/permissions/fork-pr-contributor-approval" -AllowFailure -Body @{
        approval_policy = 'all_external_contributors'
    } | Out-Null
    Write-Host '  Done.'
}

# ----------------------------------------------------------------------------- 4. Rulesets
function Set-Ruleset {
    param([Parameter(Mandatory)] $Ruleset, [Parameter(Mandatory)][string] $Summary)
    $all = @((Invoke-Gh @('api', "$RepoPath/rulesets")) -join "`n" | ConvertFrom-Json)
    $existing = @($all | Where-Object { $_ -and $_.name -eq $Ruleset.name })
    if ($existing.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($FullName, "Update ruleset '$($Ruleset.name)'")) {
            Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/rulesets/$($existing[0].id)" -Body $Ruleset | Out-Null
            Write-Host "  Updated '$($Ruleset.name)': $Summary"
        }
    }
    elseif ($PSCmdlet.ShouldProcess($FullName, "Create ruleset '$($Ruleset.name)'")) {
        Invoke-GhWithJsonBody -Method POST -Path "$RepoPath/rulesets" -Body $Ruleset | Out-Null
        Write-Host "  Created '$($Ruleset.name)': $Summary"
    }
}

$AdminRole = 5            # built-in "Repository admin" role
$GitHubActionsApp = 15368 # the GitHub Actions app (GITHUB_TOKEN)

Write-Step 'Ruleset: protect main'
$requiredChecks = @($RequiredChecks) |
    ForEach-Object { @{ context = $_; integration_id = $GitHubActionsApp } }
Set-Ruleset -Summary 'PR with code-owner approval, CI + PR title + CodeQL gates, signed commits, no force push or deletion.' -Ruleset ([ordered]@{
    name          = 'Protect main'
    target        = 'branch'
    enforcement   = 'active'
    conditions    = @{ ref_name = @{ include = @('~DEFAULT_BRANCH'); exclude = @() } }
    # Admins may bypass requirements ONLY inside a pull request (e.g. to merge their own PR, which they
    # cannot approve, or a release-please PR, whose checks don't run). Direct pushes stay impossible.
    bypass_actors = @(@{ actor_id = $AdminRole; actor_type = 'RepositoryRole'; bypass_mode = 'pull_request' })
    rules         = @(
        @{ type = 'deletion' }
        @{ type = 'non_fast_forward' }
        @{ type = 'required_signatures' }
        @{
            type       = 'pull_request'
            parameters = [ordered]@{
                required_approving_review_count   = 1
                dismiss_stale_reviews_on_push     = $true
                require_code_owner_review         = $true
                require_last_push_approval        = $false
                required_review_thread_resolution = $true
                allowed_merge_methods             = @('merge', 'squash')
            }
        }
        @{
            type       = 'required_status_checks'
            parameters = [ordered]@{
                strict_required_status_checks_policy = $true
                required_status_checks               = @($requiredChecks)
            }
        }
        @{
            type       = 'code_scanning'
            parameters = @{
                code_scanning_tools = @(@{ tool = 'CodeQL'; security_alerts_threshold = 'high_or_higher'; alerts_threshold = 'errors' })
            }
        }
    )
})

Write-Step 'Ruleset: protect release tags'
# Release tags are immutable for everyone: once published, a v* tag can never be moved or deleted.
# Creation is not restricted by the ruleset because release-please creates the tags with GITHUB_TOKEN,
# and personal repositories cannot list the GitHub Actions app as a bypass actor. Only accounts with
# write access (the maintainer and the repository's own workflows) can create tags anyway.
Set-Ruleset -Summary 'v* tags are immutable: they can never be moved or deleted.' -Ruleset ([ordered]@{
    name          = 'Protect release tags'
    target        = 'tag'
    enforcement   = 'active'
    conditions    = @{ ref_name = @{ include = @('refs/tags/v*'); exclude = @() } }
    bypass_actors = @()
    rules         = @(
        @{ type = 'update' }
        @{ type = 'deletion' }
    )
})

# ----------------------------------------------------------------------------- Manual steps
Write-Host "`nAll automated steps finished. Steps GitHub only allows from the web UI:" -ForegroundColor Green
Write-Host "  (To merge your own PRs from now on: on the PR page tick 'Merge without waiting for requirements to be met (bypass rules)'," -ForegroundColor Yellow
Write-Host "   or 'gh pr merge <n> --merge --admin'. Direct pushes to main are no longer possible, not even for you.)" -ForegroundColor Yellow
Write-Host "  1. Social preview: Settings > General > Social preview > Edit > Upload an image (1280x640)."
Write-Host "  2. Pin the repository on your profile: https://github.com/$Owner > Customize your pins."
