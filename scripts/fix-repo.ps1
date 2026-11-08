#Requires -Version 5.1
<#
.SYNOPSIS
    Re-creates every commit of a branch through the GitHub API so that GitHub signs
    them (they show as "Verified"), keeping the same history: one new commit per
    original commit, same order, same messages, same file contents.

.DESCRIPTION
    Uses only the GitHub CLI (gh). No local git repository or git commands are needed, so it
    works even when the local git identity belongs to another organization.

    Typical flow: push the branch, open the pull request, run this script, then merge the pull
    request with a merge commit. Every commit of the branch reaches main signed and Verified,
    without squashing the history.

    If gh is not installed, the script installs it with the first package manager it finds
    (winget, scoop, choco or brew), and if gh is not logged in it runs 'gh auth login'.

    How it works:
      1. Finds the commits between the base branch and the branch (compare API).
      2. Creates a temporary work branch at the merge base.
      3. Replays each commit with the GraphQL mutation createCommitOnBranch.
         Commits created by this mutation are signed by GitHub, so they are Verified.
      4. Checks that the final file tree is byte-for-byte identical to the original branch.
      5. Force-updates the original branch to the signed history, so any open pull request
         keeps working, then deletes the temporary branch.

    Limits of createCommitOnBranch, which the script checks for:
      - The author is the account gh is logged in with, and commit dates become "now".
      - File modes (executable bit) and symlinks are not supported. The script stops before
        touching your branch if the resulting tree differs from the original.
      - Merge commits cannot be replayed (the branch must have linear history).

.PARAMETER Repo
    Repository as owner/name. Asked interactively when omitted.

.PARAMETER Branch
    Branch whose commits must become verified (for example, the pull request branch).
    Asked interactively when omitted.

.PARAMETER Base
    Branch the history starts from (usually the pull request target).

.PARAMETER WorkBranch
    Temporary branch used to build the signed history.

.PARAMETER NoReplace
    Build and verify the signed history on the work branch, but do not move the original
    branch. Useful for reviewing the result first.

.PARAMETER KeepWorkBranch
    Do not delete the temporary branch at the end.

.PARAMETER Restart
    Delete a work branch left behind by an interrupted run and start again.

.NOTES
    Works on Windows PowerShell 5.1 and PowerShell 7+ (Windows, macOS, Linux).

    After the branch is re-signed, do not 'git pull' or 'git push' your local copy of it (a pull
    creates an unsigned merge commit). Update it with:
        git fetch origin <branch>
        git reset --hard origin/<branch>
    Merge the pull request with a merge commit (never "Rebase and merge", which re-creates the
    commits unsigned).

.EXAMPLE
    ./scripts/fix-repo.ps1 -Repo <owner>/<name> -Branch feat/my-change

.EXAMPLE
    # Preview only: show what would change, touch nothing.
    ./scripts/fix-repo.ps1 -Repo <owner>/<name> -Branch feat/my-change -WhatIf

.EXAMPLE
    # Build the signed history on a separate branch and leave the original untouched.
    ./scripts/fix-repo.ps1 -Repo <owner>/<name> -Branch feat/my-change -NoReplace -KeepWorkBranch
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $Repo,
    [string] $Branch,
    [string] $Base = 'main',
    [string] $WorkBranch,
    [switch] $NoReplace,
    [switch] $KeepWorkBranch,
    [switch] $Restart
)

# Lets this PowerShell process run scripts without prompts (Windows only; system settings are untouched).
if ($env:OS -eq 'Windows_NT') { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force }

while ($Repo -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    if ($Repo) { Write-Host "  '$Repo' is not in owner/name format." -ForegroundColor Yellow }
    $Repo = (Read-Host 'Repository (owner/name)').Trim()
}
while (-not $Branch) { $Branch = (Read-Host 'Branch whose commits must be signed').Trim() }
if (-not $WorkBranch) { $WorkBranch = "$Branch-signed" }
$Owner, $Repo = $Repo -split '/', 2

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false   # PowerShell 7: gh errors are handled explicitly below

# Windows PowerShell 5.1 can serialize arrays as {"value":[...],"Count":n} in ConvertTo-Json
# because of extra type data on System.Array. Removing it (only for this session) fixes that.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    Remove-TypeData -TypeName System.Array -ErrorAction SilentlyContinue
}

# $IsWindows only exists on PowerShell 6+; Windows PowerShell 5.1 always runs on Windows.
$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)

# Compact projection of the compare API: the full response embeds every diff and can be huge.
$CompareJq = '{merge_base_commit: {sha: .merge_base_commit.sha}, total_commits: .total_commits, commits: [.commits[] | {sha: .sha, parents: [.parents[] | {sha: .sha}], commit: {message: .commit.message, verification: {verified: .commit.verification.verified, reason: .commit.verification.reason}}}]}'

$RepoPath = "repos/$Owner/$Repo"

# --------------------------------------------------------------------------- helpers

function Invoke-Gh {
    <# Runs gh and returns its stdout lines. Throws with gh's own error output on failure. #>
    param([Parameter(Mandatory)][string[]] $Arguments)

    # Windows PowerShell 5.1 turns redirected stderr into terminating errors when
    # ErrorActionPreference is Stop, even if gh succeeds. Exit codes are checked instead.
    $ErrorActionPreference = 'Continue'
    # Read-only plumbing: -WhatIf must not turn the stderr redirection below into a simulation.
    $WhatIfPreference = $false
    # gh writes UTF-8; Windows PowerShell would otherwise decode it with the console code page.
    $previousEncoding = [Console]::OutputEncoding
    try { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) } catch { Write-Verbose 'Console encoding cannot be changed in this host.' }   # not settable in some hosts (ISE)
    # .NET APIs instead of New-TemporaryFile/Remove-Item so that -WhatIf does not silence them.
    $errorFile = [System.IO.Path]::GetTempFileName()
    try {
        $output = & gh @Arguments 2> $errorFile
        if ($LASTEXITCODE -ne 0) {
            $details = [System.IO.File]::ReadAllText($errorFile) + ($output -join "`n")
            throw "gh $($Arguments -join ' ') failed (exit $LASTEXITCODE):`n$details"
        }
        return $output
    }
    finally {
        [System.IO.File]::Delete($errorFile)
        try { [Console]::OutputEncoding = $previousEncoding } catch { Write-Verbose 'Console encoding cannot be changed in this host.' }
    }
}

function Test-GhCommand {
    <# Runs gh silently and returns $true if it exited with code 0. #>
    param([Parameter(Mandatory)][string[]] $Arguments)
    $ErrorActionPreference = 'Continue'
    & gh @Arguments *> $null
    return $LASTEXITCODE -eq 0
}

function Invoke-GhJson {
    <# Runs 'gh api ...' and parses the JSON response. #>
    param([Parameter(Mandatory)][string[]] $Arguments)
    $raw = (Invoke-Gh (@('api') + $Arguments)) -join "`n"
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

function Get-BranchSha {
    param([Parameter(Mandatory)][string] $Name)
    return (Invoke-GhJson @("$RepoPath/git/ref/heads/$Name")).object.sha
}

function Test-Branch {
    param([Parameter(Mandatory)][string] $Name)
    return Test-GhCommand @('api', "$RepoPath/git/ref/heads/$Name", '--silent')
}

function Get-TreeSha {
    param([Parameter(Mandatory)][string] $CommitSha)
    return (Invoke-GhJson @("$RepoPath/git/commits/$CommitSha")).tree.sha
}

function Get-CommitFile {
    <# All changed files of a commit (the files list is paginated by GitHub). #>
    param([Parameter(Mandatory)][string] $Sha)
    $lines = Invoke-Gh @('api', "$RepoPath/commits/${Sha}?per_page=100", '--paginate', '--jq', '.files[] | tojson')
    return @($lines | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

function Get-BlobBase64 {
    <# File content as base64, read from the blob API (works for files up to 100 MB). #>
    param([Parameter(Mandatory)][string] $BlobSha)
    $content = (Invoke-Gh @('api', "$RepoPath/git/blobs/$BlobSha", '--jq', '.content')) -join ''
    return ($content -replace '\s', '')
}

$CreateCommitMutation = @'
mutation ($input: CreateCommitOnBranchInput!) {
  createCommitOnBranch(input: $input) {
    commit { oid url }
  }
}
'@

function Add-SignedCommit {
    <# Creates one commit on the work branch through GraphQL. Returns the new commit SHA. #>
    param(
        [Parameter(Mandatory)][string] $ExpectedHeadOid,
        [Parameter(Mandatory)][string] $Message,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Additions,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Deletions
    )

    $lines = $Message -split "`r?`n"
    $headline = $lines[0].Trim()
    $body = (($lines | Select-Object -Skip 1) -join "`n").Trim()

    $messageInput = [ordered]@{ headline = $headline }
    if ($body) { $messageInput.body = $body }

    $request = [ordered]@{
        query     = $CreateCommitMutation
        variables = @{
            input = [ordered]@{
                branch          = @{ repositoryNameWithOwner = "$Owner/$Repo"; branchName = $WorkBranch }
                expectedHeadOid = $ExpectedHeadOid
                message         = $messageInput
                fileChanges     = @{ additions = @($Additions); deletions = @($Deletions) }
            }
        }
    }

    # The request can be large (file contents), so it is sent from a file, not the command line.
    $requestFile = [System.IO.Path]::GetTempFileName()
    try {
        $json = $request | ConvertTo-Json -Depth 20 -Compress
        [System.IO.File]::WriteAllText($requestFile, $json, [System.Text.UTF8Encoding]::new($false))
        $response = Invoke-GhJson @('graphql', '--input', $requestFile)
    }
    finally {
        [System.IO.File]::Delete($requestFile)
    }

    if ($response.PSObject.Properties.Name -contains 'errors' -and $response.errors) {
        throw "createCommitOnBranch failed: $($response.errors | ConvertTo-Json -Depth 10)"
    }
    return $response.data.createCommitOnBranch.commit.oid
}

# --------------------------------------------------------------------------- 0. GitHub CLI setup

function Sync-SessionPath {
    <# Makes a freshly installed gh visible in the current session (no new terminal needed). #>
    $separator = [System.IO.Path]::PathSeparator
    if ($OnWindows) {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user = [Environment]::GetEnvironmentVariable('Path', 'User')
        $env:PATH = (@($machine, $user, $env:PATH) | Where-Object { $_ }) -join $separator
        $candidates = @("$env:ProgramFiles\GitHub CLI", "$env:LOCALAPPDATA\Microsoft\WinGet\Links", "$env:USERPROFILE\scoop\shims")
    }
    else {
        $candidates = @('/opt/homebrew/bin', '/usr/local/bin', '/home/linuxbrew/.linuxbrew/bin')
    }
    foreach ($dir in $candidates) {
        if ((Test-Path $dir) -and (($env:PATH -split [regex]::Escape($separator)) -notcontains $dir)) {
            $env:PATH = "$env:PATH$separator$dir"
        }
    }
}

function Install-GitHubCli {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $installers = @(
        @{ Name = 'winget'; Arguments = @('install', '--id', 'GitHub.cli', '--exact', '--source', 'winget', '--accept-package-agreements', '--accept-source-agreements') }
        @{ Name = 'scoop'; Arguments = @('install', 'gh') }
        @{ Name = 'choco'; Arguments = @('install', 'gh', '-y') }
        @{ Name = 'brew'; Arguments = @('install', 'gh') }
    )
    $installer = $installers | Where-Object { Get-Command $_.Name -ErrorAction SilentlyContinue } | Select-Object -First 1
    if (-not $installer) {
        throw "GitHub CLI (gh) is not installed and no supported package manager (winget, scoop, choco, brew) was found. " +
              "Install it from https://cli.github.com and run the script again."
    }
    if (-not $PSCmdlet.ShouldProcess('this machine', "Install GitHub CLI (gh) with $($installer.Name)")) {
        Write-Warning ("GitHub CLI (gh) is needed to read the repository, so the preview stops here. " +
                       "Install it with: winget install --id GitHub.cli --exact --source winget " +
                       "(or run the script without -WhatIf and confirm the installation), then run it again.")
        return $false
    }

    Write-Host "Installing GitHub CLI with $($installer.Name)..." -ForegroundColor Cyan
    $installerArguments = $installer.Arguments
    & $installer.Name @installerArguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        $hint = if ($installer.Name -eq 'choco') { ' Chocolatey needs an elevated (administrator) PowerShell.' } else { '' }
        throw "'$($installer.Name) $($installerArguments -join ' ')' failed (exit $LASTEXITCODE).$hint"
    }

    Sync-SessionPath
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI was installed but 'gh' is not on PATH yet. Open a new terminal and run the script again."
    }
    return $true
}

Write-Host "Checking GitHub CLI..." -ForegroundColor Cyan
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    if (-not (Install-GitHubCli)) { return }
}
Write-Host "  $((& gh --version | Select-Object -First 1))"

if (-not (Test-GhCommand @('auth', 'status', '--hostname', 'github.com'))) {
    if (-not $PSCmdlet.ShouldProcess('github.com', 'Log in with gh auth login')) {
        throw "gh is not logged in to github.com. Run 'gh auth login' first."
    }
    Write-Host "gh is not logged in. Starting 'gh auth login'..." -ForegroundColor Yellow
    Write-Host "  Tip: if asked 'Authenticate Git with your GitHub credentials?', answer No to keep your current git setup." -ForegroundColor Yellow
    & gh auth login --hostname github.com --web
    if ($LASTEXITCODE -ne 0) { throw "gh auth login failed." }
}

$login = (Invoke-GhJson @('user')).login
Write-Host "  Commits will be authored and signed for GitHub user: $login"

if (-not (Test-Branch $Branch)) { throw "Branch '$Branch' does not exist in $Owner/$Repo." }
if (-not (Test-Branch $Base)) { throw "Base branch '$Base' does not exist in $Owner/$Repo." }

$branchSha = Get-BranchSha $Branch
$baseSha = Get-BranchSha $Base
$compare = Invoke-GhJson @("$RepoPath/compare/${baseSha}...${branchSha}", '--jq', $CompareJq)
$mergeBase = $compare.merge_base_commit.sha
$commits = @($compare.commits)

if ($commits.Count -eq 0) { Write-Host "Nothing to do: '$Branch' has no commits on top of '$Base'."; return }
if ($compare.total_commits -gt $commits.Count) {
    throw "The branch has $($compare.total_commits) commits; the compare API returns at most $($commits.Count). Split the work into smaller ranges."
}
$merges = @($commits | Where-Object { @($_.parents).Count -ne 1 })
if ($merges.Count -gt 0) {
    throw "Merge commits cannot be replayed: $($merges.sha -join ', '). Make the branch history linear first."
}

Write-Host "`nCommits to sign on '$Branch' (base $($mergeBase.Substring(0, 7))):" -ForegroundColor Cyan
foreach ($c in $commits) {
    $state = if ($c.commit.verification.verified) { 'verified  ' } else { 'UNVERIFIED' }
    Write-Host ("  {0}  {1}  {2}" -f $c.sha.Substring(0, 7), $state, ($c.commit.message -split "`n")[0])
}

if (-not @($commits | Where-Object { -not $_.commit.verification.verified })) {
    Write-Host "`nNothing to do: every commit on '$Branch' is already verified." -ForegroundColor Green
    return
}

if (-not $PSCmdlet.ShouldProcess("$Owner/$Repo", "Create signed copies of $($commits.Count) commits on '$WorkBranch'")) {
    return
}

# --------------------------------------------------------------------------- 1. work branch

if (Test-Branch $WorkBranch) {
    if (-not $Restart) {
        throw "Work branch '$WorkBranch' already exists (probably from an interrupted run). " +
              "Run again with -Restart to delete it and start over, or pass -WorkBranch with another name."
    }
    Invoke-Gh @('api', '-X', 'DELETE', "$RepoPath/git/refs/heads/$WorkBranch") | Out-Null
    Write-Host "Deleted the work branch '$WorkBranch' left by a previous run (-Restart)." -ForegroundColor Yellow
}
Invoke-Gh @('api', '-X', 'POST', "$RepoPath/git/refs", '-f', "ref=refs/heads/$WorkBranch", '-f', "sha=$mergeBase") | Out-Null
Write-Host "`nCreated work branch '$WorkBranch' at $($mergeBase.Substring(0, 7))." -ForegroundColor Cyan

# --------------------------------------------------------------------------- 2. replay commits

$head = $mergeBase
$mapping = [System.Collections.Generic.List[object]]::new()

foreach ($c in $commits) {
    $additions = [System.Collections.Generic.List[object]]::new()
    $deletions = [System.Collections.Generic.List[object]]::new()

    foreach ($f in Get-CommitFile $c.sha) {
        switch ($f.status) {
            'removed' { $deletions.Add(@{ path = $f.filename }) }
            'renamed' {
                $deletions.Add(@{ path = $f.previous_filename })
                $additions.Add(@{ path = $f.filename; contents = (Get-BlobBase64 $f.sha) })
            }
            'unchanged' { }
            default {
                # added, modified, changed, copied
                $additions.Add(@{ path = $f.filename; contents = (Get-BlobBase64 $f.sha) })
            }
        }
    }

    if ($additions.Count -eq 0 -and $deletions.Count -eq 0) {
        Write-Warning "Skipping $($c.sha.Substring(0, 7)): it has no file changes (empty commits are not supported)."
        continue
    }

    $newSha = Add-SignedCommit -ExpectedHeadOid $head -Message $c.commit.message `
        -Additions $additions.ToArray() -Deletions $deletions.ToArray()

    $mapping.Add([pscustomobject]@{ Old = $c.sha.Substring(0, 7); New = $newSha.Substring(0, 7); Message = ($c.commit.message -split "`n")[0] })
    Write-Host ("  {0} -> {1}  {2}" -f $c.sha.Substring(0, 7), $newSha.Substring(0, 7), ($c.commit.message -split "`n")[0])
    $head = $newSha
}

# --------------------------------------------------------------------------- 3. verify

Write-Host "`nVerifying..." -ForegroundColor Cyan
$originalTree = Get-TreeSha $branchSha
$signedTree = Get-TreeSha $head
if ($originalTree -ne $signedTree) {
    throw "The signed history does not produce the same files (tree $signedTree vs $originalTree). " +
          "'$Branch' was NOT modified; inspect '$WorkBranch' to see the difference."
}
Write-Host "  File tree identical to '$Branch' ($($originalTree.Substring(0, 7)))."

$signed = Invoke-GhJson @("$RepoPath/compare/${mergeBase}...${head}", '--jq', $CompareJq)
$unverified = @($signed.commits | Where-Object { -not $_.commit.verification.verified })
foreach ($c in $signed.commits) {
    Write-Host ("  {0}  verified={1} ({2})" -f $c.sha.Substring(0, 7), $c.commit.verification.verified, $c.commit.verification.reason)
}
if ($unverified.Count -gt 0) {
    throw "$($unverified.Count) new commit(s) are not verified. '$Branch' was NOT modified; see '$WorkBranch'."
}

# --------------------------------------------------------------------------- 4. replace the branch

if ($NoReplace) {
    Write-Host "`nDone. Signed history is on '$WorkBranch'; '$Branch' was left unchanged (-NoReplace)." -ForegroundColor Green
    return
}

if ($PSCmdlet.ShouldProcess($Branch, "Force-update to the signed history ($($head.Substring(0, 7)))")) {
    # Guard against someone pushing to the branch while the script was running.
    if ((Get-BranchSha $Branch) -ne $branchSha) {
        throw "'$Branch' changed while the script was running. It was NOT modified; the signed history is on '$WorkBranch'."
    }
    Invoke-Gh @('api', '-X', 'PATCH', "$RepoPath/git/refs/heads/$Branch", '-f', "sha=$head", '-F', 'force=true') | Out-Null
    Write-Host "`n'$Branch' now points to the signed history. Open pull requests are updated automatically." -ForegroundColor Green

    if (-not $KeepWorkBranch) {
        Invoke-Gh @('api', '-X', 'DELETE', "$RepoPath/git/refs/heads/$WorkBranch") | Out-Null
        Write-Host "Deleted work branch '$WorkBranch'."
    }
}

$mapping | Format-Table -AutoSize
