#Requires -Version 5.1
<#
.SYNOPSIS
    Applies the GitHub settings that cannot live in files: About, topics, labels, merge options,
    security features, Actions hardening and the rulesets that protect a branch and the release tags.

    Result: nobody (maintainer included) can push to the protected branch without a pull request;
    anyone can fork and open pull requests, but their workflows only run after a maintainer
    approves them.

.DESCRIPTION
    Runs from any folder: it only talks to the GitHub API through the GitHub CLI (gh), so the
    repository does not need to be cloned. If gh is not authenticated it starts 'gh auth login'.
    The authenticated account must be an admin of the repository.

    Idempotent: rulesets are created or updated by name, so it can be run again at any time (for
    example after adding a CI job that must become a required check).

    Run it AFTER the first pull request is merged: the signed-commits rule would otherwise block
    a first pull request whose commits are not signed.

    Works on Windows PowerShell 5.1 and PowerShell 7+ (Windows, macOS, Linux).

.PARAMETER Repo
    Repository as owner/name. Asked interactively when omitted.

.PARAMETER Branch
    Branch protected by the ruleset. Asked interactively when omitted (Enter = default branch).

.PARAMETER RequiredChecks
    Status check (job) names that must pass before merging. When omitted, the check runs of the
    latest commit on the branch are proposed and you confirm them. Pass '' to require none.

.PARAMETER Description
    The "About" text. Left unchanged when omitted.

.PARAMETER Topics
    Repository topics (at most 20). Left unchanged when omitted.

.PARAMETER Homepage
    The "About" website. Left unchanged when omitted.

.PARAMETER AllowedActions
    Third-party actions allowed to run (GitHub-owned actions are always allowed). Every action used
    in .github/workflows must be listed here.

.PARAMETER RequireSignedCommits
    Require signed commits on the protected branch (default: $true). Commits re-created with
    scripts/fix-repo.ps1 and squash merges made on GitHub are signed by GitHub.

.PARAMETER Template
    Marks the repository as a template repository.

.EXAMPLE
    ./scripts/setup-repo.ps1 -WhatIf

.EXAMPLE
    ./scripts/setup-repo.ps1 -Repo owner/name -Branch main -RequiredChecks markdown,editorconfig,actionlint,conventional-commits

.EXAMPLE
    ./scripts/setup-repo.ps1 -Repo owner/my-api -Description 'Orders API' -Topics dotnet,api
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $Repo,
    [string] $Branch,
    [string[]] $RequiredChecks,
    [string] $Description,
    [string[]] $Topics,
    [string] $Homepage,
    [string[]] $AllowedActions = @(
        'amannn/action-semantic-pull-request@*',
        'googleapis/release-please-action@*',
        'ossf/scorecard-action@*',
        'DavidAnson/markdownlint-cli2-action@*',
        'editorconfig-checker/action-editorconfig-checker@*',
        'raven-actions/actionlint@*'
    ),
    [bool] $RequireSignedCommits = $true,
    [switch] $Template
)

# Lets this PowerShell process run scripts without prompts (Windows only; system settings are untouched).
if ($env:OS -eq 'Windows_NT') { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue   # 5.1 ConvertTo-Json array fix
}
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# --------------------------------------------------------------------------- helpers

function Invoke-Gh {
    <# Runs gh, returns stdout lines, throws with gh's error output on failure. #>
    param([Parameter(Mandatory)][string[]] $Arguments, [switch] $AllowFailure)
    $ErrorActionPreference = 'Continue'
    $WhatIfPreference = $false
    $previousEncoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = $Utf8NoBom } catch { Write-Verbose 'Console encoding cannot be changed in this host.' }
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & gh @Arguments 2> $errorFile
        if ($LASTEXITCODE -ne 0) {
            # gh prints the API's error body (with the validation details) on stdout.
            $details = ([System.IO.File]::ReadAllText($errorFile) + "`n" + ($output -join "`n")).Trim()
            if ($AllowFailure) { Write-Verbose "gh $($Arguments -join ' ') failed: $details"; return $null }
            throw "gh $($Arguments -join ' ') failed (exit $LASTEXITCODE):`n$details"
        }
        if ($null -eq $output) { return '' }
        return $output
    }
    finally {
        [System.IO.File]::Delete($errorFile)
        try { [Console]::OutputEncoding = $previousEncoding } catch { Write-Verbose 'Console encoding cannot be changed in this host.' }
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
    <# Sends a JSON body from a temp file (avoids quoting and encoding problems on the command line). #>
    param([Parameter(Mandatory)][string] $Method, [Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Body, [switch] $AllowFailure)
    $file = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($file, ($Body | ConvertTo-Json -Depth 20), $Utf8NoBom)
        return Invoke-Gh @('api', '-X', $Method, $Path, '--input', $file) -AllowFailure:$AllowFailure
    }
    finally { [System.IO.File]::Delete($file) }
}

function Write-Step([string] $Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }

function Sync-Ruleset {
    <# Creates or updates a ruleset by name so the script can be re-run safely. #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)] $Ruleset, [Parameter(Mandatory)][string] $Summary)
    $all = @((Invoke-Gh @('api', "$RepoPath/rulesets")) -join "`n" | ConvertFrom-Json)
    $existing = @($all | Where-Object { $_ -and $_.name -eq $Ruleset.name })
    if ($existing.Count -gt 0) {
        if ($PSCmdlet.ShouldProcess($Repo, "Update ruleset '$($Ruleset.name)'")) {
            Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/rulesets/$($existing[0].id)" -Body $Ruleset | Out-Null
            Write-Host "  Updated '$($Ruleset.name)': $Summary"
        }
    }
    elseif ($PSCmdlet.ShouldProcess($Repo, "Create ruleset '$($Ruleset.name)'")) {
        Invoke-GhWithJsonBody -Method POST -Path "$RepoPath/rulesets" -Body $Ruleset | Out-Null
        Write-Host "  Created '$($Ruleset.name)': $Summary"
    }
}

# --------------------------------------------------------------------------- prerequisites

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required: https://cli.github.com (Windows: winget install --id GitHub.cli --exact)'
}
if (-not (Test-Gh @('auth', 'status', '--hostname', 'github.com'))) {
    Write-Host "gh is not logged in. Starting 'gh auth login'..." -ForegroundColor Yellow
    Write-Host "  Tip: if asked 'Authenticate Git with your GitHub credentials?', answer No to keep your git setup." -ForegroundColor Yellow
    & gh auth login --hostname github.com --git-protocol https --web
    if (-not (Test-Gh @('auth', 'status', '--hostname', 'github.com'))) { throw 'GitHub authentication failed.' }
}

# --------------------------------------------------------------------------- inputs

while ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    if ($Repo) { Write-Host "  '$Repo' is not in owner/name format." -ForegroundColor Yellow }
    $Repo = (Read-Host 'Repository (owner/name)').Trim()
}
$RepoPath = "repos/$Repo"

$repoInfo = Invoke-Gh @('api', $RepoPath) -AllowFailure
if (-not $repoInfo) { throw "Repository '$Repo' not found or not accessible." }
$repoInfo = ($repoInfo -join "`n") | ConvertFrom-Json
if (-not $repoInfo.permissions.admin) { throw "The authenticated account is not an admin of '$Repo'." }

if (-not $Branch) {
    $answer = (Read-Host "Branch to protect [$($repoInfo.default_branch)]").Trim()
    $Branch = if ($answer) { $answer } else { $repoInfo.default_branch }
}
if (-not (Test-Gh @('api', "$RepoPath/branches/$Branch", '--silent'))) { throw "Branch '$Branch' does not exist in '$Repo'." }

if (-not $PSBoundParameters.ContainsKey('RequiredChecks')) {
    # Propose the check runs of the latest commit on the branch. CodeQL is excluded: it is enforced
    # through the code scanning rule instead.
    $detected = @(Invoke-Gh @('api', "$RepoPath/commits/$Branch/check-runs?per_page=100",
            '--jq', '[.check_runs[].name] | unique | map(select(test("^(Analyze|CodeQL)") | not)) | .[]') -AllowFailure |
        Where-Object { $_ })
    if ($detected.Count -gt 0) {
        Write-Host "Checks found on the latest commit of ${Branch}: $($detected -join ', ')"
        $answer = (Read-Host 'Required status checks, comma separated [Enter = all of the above, "-" = none]').Trim()
    }
    else {
        $answer = (Read-Host 'Required status checks, comma separated [Enter = none]').Trim()
    }
    $RequiredChecks = if ($answer -eq '-') { @() } elseif ($answer) { $answer -split '\s*,\s*' } else { $detected }
}
$RequiredChecks = @($RequiredChecks | Where-Object { $_ })
if ($Topics -and @($Topics).Count -gt 20) { throw "GitHub allows at most 20 topics; got $(@($Topics).Count)." }

$hasCodeScanning = Test-Gh @('api', "$RepoPath/code-scanning/analyses?per_page=1", '--silent')

Write-Host "`nConfiguring $Repo" -ForegroundColor Green
Write-Host "  protected branch : $Branch"
Write-Host "  required checks  : $(if ($RequiredChecks.Count) { $RequiredChecks -join ', ' } else { '(none)' })"
Write-Host "  CodeQL gate      : $(if ($hasCodeScanning) { 'yes' } else { 'no (no code scanning analyses yet; re-run after CodeQL has run)' })"
Write-Host "  signed commits   : $RequireSignedCommits"

# --------------------------------------------------------------------------- 1. About and merge options

Write-Step 'About and merge options'
if ($PSCmdlet.ShouldProcess($Repo, 'Set merge options and About')) {
    $settings = [ordered]@{
        allow_merge_commit          = $true
        allow_squash_merge          = $true
        allow_rebase_merge          = $false
        squash_merge_commit_title   = 'PR_TITLE'
        squash_merge_commit_message = 'PR_BODY'
        delete_branch_on_merge      = $true
        allow_update_branch         = $true
        has_wiki                    = $false
        has_projects                = $false
        has_issues                  = $true
    }
    if ($Description) { $settings.description = $Description }
    if ($Homepage) { $settings.homepage = $Homepage }
    if ($Template) { $settings.is_template = $true }
    Invoke-GhWithJsonBody -Method PATCH -Path $RepoPath -Body $settings | Out-Null
    if ($Topics) {
        Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/topics" -Body @{ names = @($Topics | ForEach-Object { $_.ToLowerInvariant() }) } | Out-Null
    }
    Write-Host '  Done.'
}

# --------------------------------------------------------------------------- 2. Labels

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
)
if ($PSCmdlet.ShouldProcess($Repo, "Create or update $($labels.Count) labels")) {
    foreach ($label in $labels) {
        Invoke-Gh @('label', 'create', $label.Name, '--repo', $Repo, '--color', $label.Color, '--description', $label.Description, '--force') | Out-Null
    }
    Write-Host '  Done.'
}

# --------------------------------------------------------------------------- 3. Security features

Write-Step 'Security features'
if ($PSCmdlet.ShouldProcess($Repo, 'Enable Dependabot alerts and security updates, private vulnerability reporting, secret scanning')) {
    Invoke-Gh @('api', '-X', 'PUT', "$RepoPath/vulnerability-alerts") -AllowFailure | Out-Null
    Invoke-Gh @('api', '-X', 'PUT', "$RepoPath/automated-security-fixes") -AllowFailure | Out-Null
    if ($null -eq (Invoke-Gh @('api', '-X', 'PUT', "$RepoPath/private-vulnerability-reporting") -AllowFailure)) {
        Write-Host '  (private vulnerability reporting is not available for this repository)'
    }
    $secretScanning = @{
        security_and_analysis = @{
            secret_scanning                 = @{ status = 'enabled' }
            secret_scanning_push_protection = @{ status = 'enabled' }
        }
    }
    if ($null -eq (Invoke-GhWithJsonBody -Method PATCH -Path $RepoPath -Body $secretScanning -AllowFailure)) {
        Write-Host '  (secret scanning needs a public repository or GitHub Advanced Security)'
    }
    Write-Host '  Done.'
}

# --------------------------------------------------------------------------- 4. Actions hardening

Write-Step 'GitHub Actions hardening'
if ($PSCmdlet.ShouldProcess($Repo, 'Read-only GITHUB_TOKEN, allow-listed and SHA-pinned actions, approval for fork workflows')) {
    # Read-only token by default. 'can_approve_pull_request_reviews' is GitHub's single switch for
    # "Allow GitHub Actions to create and approve pull requests": release-please needs it to open release
    # pull requests. An approval from Actions never satisfies the code-owner review the ruleset requires.
    Invoke-Gh @('api', '-X', 'PUT', "$RepoPath/actions/permissions/workflow",
        '-f', 'default_workflow_permissions=read', '-F', 'can_approve_pull_request_reviews=true') | Out-Null

    # Only GitHub-owned actions plus an explicit allow-list, and (where supported) only full-SHA references.
    $policy = Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/actions/permissions" -AllowFailure -Body @{
        enabled = $true; allowed_actions = 'selected'; sha_pinning_required = $true
    }
    if ($null -eq $policy) {
        Write-Host '  SHA pinning policy not available for this account; applying the allow-list only.'
        Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/actions/permissions" -Body @{ enabled = $true; allowed_actions = 'selected' } | Out-Null
    }
    Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/actions/permissions/selected-actions" -Body @{
        github_owned_allowed = $true
        verified_allowed     = $false
        patterns_allowed     = @($AllowedActions)
    } | Out-Null

    # Workflows triggered by pull requests from forks of outside contributors wait for approval.
    if ($null -eq (Invoke-GhWithJsonBody -Method PUT -Path "$RepoPath/actions/permissions/fork-pr-contributor-approval" -AllowFailure -Body @{
                approval_policy = 'all_external_contributors' })) {
        Write-Host '  (set it in Settings > Actions > General > Fork pull request workflows)'
    }
    Write-Host '  Done.'
}

# --------------------------------------------------------------------------- 5. Rulesets

$AdminRole = 5   # built-in "Repository admin" role

Write-Step "Ruleset: protect $Branch"
$rules = [System.Collections.Generic.List[object]]::new()
$rules.Add(@{ type = 'deletion' })
$rules.Add(@{ type = 'non_fast_forward' })
if ($RequireSignedCommits) { $rules.Add(@{ type = 'required_signatures' }) }
$rules.Add(@{
        type       = 'pull_request'
        parameters = [ordered]@{
            required_approving_review_count   = 1
            dismiss_stale_reviews_on_push     = $true
            require_code_owner_review         = $true
            require_last_push_approval        = $false
            required_review_thread_resolution = $true
            allowed_merge_methods             = @('merge', 'squash')
        }
    })
if ($RequiredChecks.Count -gt 0) {
    $rules.Add(@{
            type       = 'required_status_checks'
            parameters = [ordered]@{
                strict_required_status_checks_policy = $false
                required_status_checks               = @($RequiredChecks | ForEach-Object { @{ context = $_ } })
            }
        })
}
if ($hasCodeScanning) {
    $rules.Add(@{
            type       = 'code_scanning'
            parameters = @{
                code_scanning_tools = @(@{ tool = 'CodeQL'; security_alerts_threshold = 'high_or_higher'; alerts_threshold = 'errors' })
            }
        })
}
Sync-Ruleset -Summary 'pull requests only, code-owner approval, required checks, signed commits, no force push or deletion.' -Ruleset ([ordered]@{
        name          = "Protect $Branch"
        target        = 'branch'
        enforcement   = 'active'
        conditions    = @{ ref_name = @{ include = @("refs/heads/$Branch"); exclude = @() } }
        # Admins may bypass requirements ONLY inside a pull request (to merge their own pull request,
        # which they cannot approve, or a release-please pull request, whose checks don't run).
        # Direct pushes stay impossible.
        bypass_actors = @(@{ actor_id = $AdminRole; actor_type = 'RepositoryRole'; bypass_mode = 'pull_request' })
        rules         = $rules.ToArray()
    })

Write-Step 'Ruleset: protect release tags'
# Release tags are immutable for everyone: once published, a v* tag can never be moved or deleted.
# Creation is not restricted because release-please creates the tags with GITHUB_TOKEN, and personal
# repositories cannot list the GitHub Actions app as a bypass actor.
Sync-Ruleset -Summary 'v* tags are immutable: they can never be moved or deleted.' -Ruleset ([ordered]@{
        name          = 'Protect release tags'
        target        = 'tag'
        enforcement   = 'active'
        conditions    = @{ ref_name = @{ include = @('refs/tags/v*'); exclude = @() } }
        bypass_actors = @()
        rules         = @(@{ type = 'update' }, @{ type = 'deletion' }, @{ type = 'non_fast_forward' })
    })

# --------------------------------------------------------------------------- manual steps

Write-Host "`nDone: https://github.com/$Repo/settings/rules" -ForegroundColor Green
Write-Host "  To merge your own pull requests: tick 'Merge without waiting for requirements to be met (bypass rules)'" -ForegroundColor Yellow
Write-Host "  or run 'gh pr merge <n> --repo $Repo --merge --admin'. Direct pushes to $Branch are no longer possible." -ForegroundColor Yellow
Write-Host '  Only in the web UI: Settings > General > Social preview (1280x640 image).'
