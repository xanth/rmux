<#
.SYNOPSIS
Moves the RMUX fix branches onto a release tag, checks them, and pushes them.

.DESCRIPTION
Fix branches are every local fix/* branch. Each must be checked out, clean, in its own
worktree.

Fixes are based on the tag's fork point: git merge-base <tag> origin/main. A pull request
from a fix to upstream main then carries only the fix's own commits, and merging the fix onto
the tag adds only the fix.

1. Rebases each fix onto the fork point from the base it was cut from: the parent of its
   first own commit, where own commits are on no origin branch or tag. A fix already on the
   fork point is left alone.
2. Checks that each fix is a linear series of its own commits, each with a Signed-off-by
   trailer (RMUX's DCO).
3. Checks that no two fixes change the same file.
4. Merges every fix onto the tag in a dry run that creates no branch, and checks that each
   fix's files change exactly as the fix changes them. Prints the merged commit, which
   Build-PatchSet.ps1 packages.
5. Pushes every fix to the fork in one atomic push, each with --force-with-lease on the
   fork's state when the run started, unless -NoPush.

All or nothing: if a rebase, a check or the push fails, the script aborts it, resets every
fix to where it started, and names the cause. Fix the affected branches by hand, then run it
again.

.EXAMPLE
pwsh Update-PatchSet.ps1 -Tag v0.10.0
#>
#Requires -Version 7.4
param(
    [Parameter(Mandatory)]
    [string] $Tag,
    [switch] $NoPush
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$fork = 'xanth'
$prefix = 'fix'

function Invoke-Git { git -C $PSScriptRoot @args }
function Get-OwnCommit([string] $ref) { @(Invoke-Git rev-list --reverse $ref --not --remotes=origin --tags) }
function Get-PatchId { @(Invoke-Git diff @args | git -C $PSScriptRoot patch-id --stable) -split ' ' | Select-Object -First 1 }

Invoke-Git fetch --quiet origin
$tagTip = Invoke-Git rev-parse "$Tag^{commit}"
$forkPoint = Invoke-Git merge-base $tagTip refs/remotes/origin/main
$fixes = @(Invoke-Git for-each-ref --format='%(refname:short)' "refs/heads/$prefix/")
if ($fixes.Count -eq 0) { throw "No fix branches match $prefix/*." }

$worktrees = @{}
foreach ($line in Invoke-Git worktree list --porcelain) {
    if ($line -like 'worktree *') { $path = $line.Substring(9) }
    elseif ($line -like 'branch refs/heads/*') { $worktrees[$line.Substring(18)] = $path }
}
$start = @{}
foreach ($fix in $fixes) {
    if (-not $worktrees[$fix]) { throw "No worktree has $fix checked out." }
    if (git -C $worktrees[$fix] status --porcelain) { throw "$($worktrees[$fix]) has uncommitted changes." }
    $start[$fix] = Invoke-Git rev-parse $fix
}
if (-not $NoPush) {
    Invoke-Git fetch --quiet $fork
    $leases = foreach ($fix in $fixes) {
        "--force-with-lease=refs/heads/${fix}:$(Invoke-Git for-each-ref --format='%(objectname)' "refs/remotes/$fork/$fix")"
    }
}

try {
    foreach ($fix in $fixes) {
        $own = @(Get-OwnCommit $fix)
        if ($own.Count -eq 0) { throw "$fix has no commits of its own. Retire it." }
        $base = Invoke-Git rev-parse "$($own[0])^"
        if ($base -eq $forkPoint) { continue }
        try { git -C $worktrees[$fix] rebase --quiet --onto $forkPoint $base }
        catch { throw "$fix does not rebase cleanly onto the $Tag fork point. In its worktree run: git rebase --onto $forkPoint $base" }
    }

    foreach ($fix in $fixes) {
        $commits = @(Invoke-Git rev-list --reverse "$forkPoint..$fix")
        if ($commits.Count -eq 0) { throw "$fix has no commits left on the $Tag fork point, so upstream has it. Retire it." }
        $merges = @(Invoke-Git rev-list --merges "$forkPoint..$fix")
        if (@(Get-OwnCommit $fix).Count -ne $commits.Count -or $merges.Count -gt 0 -or
            (Invoke-Git rev-parse "$($commits[0])^") -ne $forkPoint) {
            throw "$fix must be a linear series of its own commits on the $Tag fork point."
        }
        foreach ($commit in $commits) {
            if (-not (Invoke-Git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' $commit)) {
                throw "$fix commit $commit has no Signed-off-by trailer (git commit -s)."
            }
        }
    }

    $fixPaths = @{}
    foreach ($fix in $fixes) { $fixPaths[$fix] = @(Invoke-Git diff --name-only $forkPoint $fix) }
    $shared = $fixes | ForEach-Object { $fixPaths[$_] } | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name
    if ($shared) { throw "Files changed by more than one fix: $($shared -join ', ')" }

    $merged = $tagTip
    foreach ($fix in $fixes) {
        try { $tree = @(Invoke-Git merge-tree --write-tree $merged $fix)[0] }
        catch { throw "$fix does not merge cleanly onto $Tag." }
        $merged = Invoke-Git commit-tree $tree -p $merged -p $fix -m "Merge $fix onto $Tag"
    }
    foreach ($fix in $fixes) {
        $paths = $fixPaths[$fix]
        if ((Get-PatchId $forkPoint $fix '--' @paths) -ne (Get-PatchId $tagTip $merged '--' @paths)) {
            throw "Merged onto $Tag, $($paths -join ', ') do not change exactly as $fix changes them."
        }
    }

    if (-not $NoPush) {
        try { Invoke-Git push --quiet --atomic @leases $fork @fixes }
        catch { throw "The push to $fork was refused, so the fork still has the old version of every fix." }
    }
}
catch {
    $PSNativeCommandUseErrorActionPreference = $false
    foreach ($fix in $fixes) {
        $worktree = $worktrees[$fix]
        $gitDir = git -C $worktree rev-parse --absolute-git-dir
        if ((Test-Path "$gitDir/rebase-merge") -or (Test-Path "$gitDir/rebase-apply")) {
            git -C $worktree rebase --abort 2>$null
        }
        git -C $worktree reset --hard --quiet $start[$fix]
    }
    throw "$($_.Exception.Message) Every fix is back where it started."
}

foreach ($fix in $fixes) { Invoke-Git log -1 --format="%h $fix  %s" $fix }
Write-Output "merged=$merged"
