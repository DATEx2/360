<#
.SYNOPSIS
    Commits and pushes changed/untracked Git files in size-limited batches.

.DESCRIPTION
    This script identifies modified, added, and untracked files in a Git repository.
    It then processes these files, staging them and committing them in batches
    where the total size of files in each batch does not exceed a specified limit (default 500MB).
    Each successful batch is then pushed to the remote repository.

.NOTES
    - Requires Git to be installed and accessible in the system's PATH.
    - Requires the current directory to be the root of a Git repository.
    - Ensures your Git username and email are configured.
    - Ensures your current branch is tracking an upstream branch.
    - Logging output to git_batch_log.txt in the repository root.
    - Skips directories and deleted files for batching.
    - Handles paths with spaces and special characters.
    - The log file 'git_batch_log.txt' is automatically excluded from commits.
      It's recommended to add 'git_batch_log.txt' to your repository's .gitignore.

.EXAMPLE
    .\git_batch_push.ps1
    Runs the script with default 500MB batch size.

.EXAMPLE
    .\git_batch_push.ps1 -MaxBatchSizeMB 100
    Runs the script with a 100MB batch size.
#>
param(
    [Parameter(Mandatory=$false)]
    [int]$MaxBatchSizeMB = 500,

    [Parameter(Mandatory=$false)]
    [string]$CommitMessagePrefix = "Initial Commit" # Commit message prefix
)

# Set error action preference to stop script on any non-terminating error
$ErrorActionPreference = 'Stop'

# Define log file path (relative to repo root)
$LogFilePath = Join-Path (Get-Location).Path "git_batch_log.txt"
# Get just the filename for exclusion comparison
# Use a try/catch here in case log file doesn't exist yet, to prevent script halt on startup
try {
    $LogFileName = (Get-Item $LogFilePath -ErrorAction Stop).Name
} catch {
    # If the log file doesn't exist yet, we still know its intended name
    $LogFileName = "git_batch_log.txt"
}


# Convert MB to Bytes for calculation
$MaxBatchSizeBytes = $MaxBatchSizeMB * 1MB # 1MB = 1024*1024 bytes

# --- Helper Functions ---

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO" # INFO, WARN, ERROR
    )
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [$Level] $Message"
    Write-Host $LogMessage # Also output to console
    Add-Content -Path $LogFilePath -Value $LogMessage # Write to log file
}

function Invoke-GitCommand {
    param(
        [string]$Command,
        [array]$Arguments = @(),
        [switch]$NoLog # Corrected: Changed from [bool] to [switch] to work as a flag
    )
    $FullCommand = "git $Command $($Arguments -join ' ')" # Correctly join arguments for logging
    if (-not $NoLog) { # If NoLog switch is NOT present (i.e., we want to log this command)
        Write-Log "Running: $FullCommand"
    }

    # Execute git command and capture all output (stdout and stderr)
    $commandOutput = & git $Command $Arguments 2>&1
    $LastGitExitCode = $LASTEXITCODE # Get the exit code of the last executed external program

    if ($LastGitExitCode -ne 0) {
        # Actual error: non-zero exit code from Git
        Write-Log "Git command failed: $FullCommand" -Level "ERROR"
        Write-Log "Error Output: $($commandOutput | Out-String)" -Level "ERROR" # Convert to string for better logging
        throw "Git command failed with exit code $LastGitExitCode. Check log for details."
    } else {
        # Command succeeded (exit code 0), but check for warnings in output
        $warnings = $commandOutput | Where-Object { $_ -match "^warning:" }
        if ($warnings) {
            $warnings | ForEach-Object { Write-Log "Git Warning: $_" -Level "WARN" }
            # IMPORTANT: Do NOT throw an error here, as it's only a warning.
        }

        # Filter out warnings from the returned result and return actual command output (if any)
        return $commandOutput | Where-Object { $_ -notmatch "^warning:" }
    }
}

function Commit-And-Push-Batch {
    param(
        [int]$BatchNumber,
        [long]$BatchSize,
        [string[]]$FilesToAddRelativePaths # These are the relative paths from repo root
    )

    if ($FilesToAddRelativePaths.Count -eq 0) {
        Write-Log "Attempted to commit an empty batch. Skipping." -Level "WARN"
        return
    }

    Write-Log "`n--- Committing Batch $BatchNumber ($([Math]::Round($BatchSize / 1MB, 2))MB) ---"
    Write-Log "Files in this batch:"
    $FilesToAddRelativePaths | ForEach-Object { Write-Log "  - $_" }

    try {
        # Stage files using a temporary file for --pathspec-from-file to handle paths with spaces/special characters
        # Using a GUID to ensure unique temp file name
        $tempFile = Join-Path $env:TEMP "git_batch_files_$(New-Guid).tmp"

        # *** CRITICAL FIX FOR UTF8NoBOM ON POWERSHELL 5.1 AND OLDER ***
        # Create a UTF8Encoding object without a BOM
        $utf8NoBOM = New-Object System.Text.UTF8Encoding($false) # $false parameter ensures no BOM
        # Write all lines to the file using this specific encoding
        [System.IO.File]::WriteAllLines($tempFile, $FilesToAddRelativePaths, $utf8NoBOM)

        Write-Log "Staging files for batch $BatchNumber..."
        Invoke-GitCommand "add" "--pathspec-from-file=$tempFile"

        $commitMessage = "$CommitMessagePrefix - Batch $BatchNumber"
        Write-Log "Committing batch $BatchNumber..."
        Invoke-GitCommand "commit" "-m", $commitMessage

        Write-Log "Pushing Batch $BatchNumber to origin/$CurrentBranch..."
        Invoke-GitCommand "push" "origin", $CurrentBranch
        
        Write-Log "Batch $BatchNumber committed and pushed successfully."
    } catch {
        # Catch specific errors from Invoke-GitCommand or other operations within this function
        Write-Log "Error during batch commit/push: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "Please resolve issues and try again. Files for batch $BatchNumber might be staged or committed." -Level "ERROR"
        exit 1 # Exit script on critical error
    } finally {
        # Clean up the temporary file used for git add, even if an error occurred
        if (Test-Path $tempFile) {
            Remove-Item $tempFile -ErrorAction SilentlyContinue
        }
    }
}

# --- Script Execution ---
Write-Log "--- Git Batch Commit and Push Script ---"
Write-Log "Max batch size: $($MaxBatchSizeMB)MB"
Write-Log "Log file: $LogFilePath"
Write-Log "Script started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

try {
    # --- Prerequisites Check ---
    Write-Log "Checking Git environment..."
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw "Git is not installed or not in your PATH. Please install Git."
    }

    # Check if we are in a Git repository root
    if (-not (Invoke-GitCommand "rev-parse" "--is-inside-work-tree" -NoLog)) {
        throw "Not in a Git repository. Please navigate to your repository root."
    }

    # Get current branch name
    $CurrentBranch = (Invoke-GitCommand "rev-parse" "--abbrev-ref", "HEAD" -NoLog).Trim()
    if ([string]::IsNullOrWhiteSpace($CurrentBranch)) {
        throw "Could not determine current Git branch."
    }
    Write-Log "Current branch: $CurrentBranch"

    # Fetch latest changes from remote
    Write-Log "Fetching latest changes from remote (origin/$CurrentBranch)..."
    Invoke-GitCommand "fetch" "origin"

    # --- Get Changed and Untracked Files ---
    Write-Log "Detecting changed and untracked files..."

    # Get porcelain status output for untracked and modified/added/renamed/copied files
    $statusOutput = Invoke-GitCommand "status" "--porcelain", "-uall"
    
    $filesToProcess = @() # Array to hold custom objects {Path, Size, RelativePath}
    foreach ($line in $statusOutput) {
        $statusCode = $line.Substring(0, 2)
        $filePath = $line.Substring(3).Trim() # Get the path, trim leading space for renamed files

        # --- IMPORTANT FIX: EXCLUDE THE LOG FILE ITSELF (PowerShell 5.1 compatible) ---
        # Get the item. If it doesn't exist or is a directory, $item will be $null or not a file.
        $itemToFilter = Get-Item -LiteralPath $filePath -ErrorAction SilentlyContinue

        # Only proceed if it's an actual file and its name matches our log file name
        if ($itemToFilter -and (-not $itemToFilter.PSIsContainer) -and ($itemToFilter.Name -eq $LogFileName)) {
            Write-Log "Skipping internal log file from Git processing: $filePath" -Level "INFO"
            continue # Skip this file
        }

        # Handle renamed files: "R  old_path -> new_path" format (e.g., "R  old_name.txt -> new_name.txt")
        # Git status --porcelain for renamed files has format "R[M] <old_path> -> <new_path>"
        if ($statusCode.StartsWith('R') -and $filePath.Contains('->')) {
            $filePath = ($filePath -split '-> ')[1].Trim() # Take the part after '->'
        }

        # Exclude deleted files (D status on either side)
        if ($statusCode.Contains('D')) {
            continue # Skip deleted files
        }

        # Only process untracked (??), modified (M), added (A), copied (C), or renamed (R) files
        # Ensure it's an actual file and exists, not a directory
        if ($statusCode -match '^\?\?|^M|^A|^C|^R') {
            try {
                # Use -LiteralPath for paths with special characters (like square brackets)
                # We already did a preliminary Get-Item for filtering the log file,
                # but if that was skipped, we need to get it again for full details.
                $item = Get-Item -LiteralPath $filePath -ErrorAction Stop
                if ($item.PSIsContainer) { # Check if it's a directory
                    continue # Skip directories
                }
                
                $filesToProcess += [PSCustomObject]@{
                    Path = $item.FullName # Full path on the system
                    Size = $item.Length   # File size in bytes
                    RelativePath = $filePath # Path relative to repo root for git commands
                }
            } catch {
                Write-Log "Warning: Could not get details for '$filePath'. Skipping. Error: $($_.Exception.Message)" -Level "WARN"
            }
        }
    }

    if ($filesToProcess.Count -eq 0) {
        Write-Log "No changed or untracked files found to commit."
        exit 0
    }

    Write-Log "Found $($filesToProcess.Count) files to process."
    # Sort files by relative path for consistent processing order
    $filesToProcess = $filesToProcess | Sort-Object RelativePath

    # --- Batching Logic ---
    $currentBatchSizeBytes = 0
    $batchFiles = @() # Array to hold file objects for the current batch
    $batchCount = 1

    foreach ($file in $filesToProcess) {
        # Check if adding the current file would exceed the batch size AND if there are files already in the batch.
        # This ensures we don't commit an empty batch or a batch with only one file larger than the limit if that's the first file.
        if (($currentBatchSizeBytes + $file.Size -gt $MaxBatchSizeBytes) -and ($batchFiles.Count -gt 0)) {
            Commit-And-Push-Batch -BatchNumber $batchCount -BatchSize $currentBatchSizeBytes -FilesToAdd ($batchFiles.RelativePath)
            $currentBatchSizeBytes = 0
            $batchFiles = @()
            $batchCount++
        }

        $currentBatchSizeBytes += $file.Size
        $batchFiles += $file
    }

    # Commit any remaining files in the last batch
    if ($batchFiles.Count -gt 0) {
        Commit-And-Push-Batch -BatchNumber $batchCount -BatchSize $currentBatchSizeBytes -FilesToAdd ($batchFiles.RelativePath)
    } else {
        Write-Log "All files processed and committed (if any)."
    }

} catch {
    # Catch any unhandled errors from the main script execution
    Write-Log "Script execution failed: $($_.Exception.Message)" -Level "ERROR"
    Write-Log "See log file '$LogFilePath' for more details." -Level "ERROR"
    exit 1
} finally {
    # This block always executes, whether script succeeds or fails
    Write-Log "Script finished at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
}