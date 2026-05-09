# GitHub Releases Temporary Staging

This folder is configured as a lightweight GitHub Releases staging area.

Put files to back up temporarily in `payload/`. The Git repository should only
track the helper files in this folder, not the large payload files.

## One-time setup

1. Create a GitHub repository. If the repository is public, release assets are
   public too.
2. Push this helper repository to GitHub:

```powershell
git init
git add .gitignore README.md scripts payload/.gitkeep release-artifacts/.gitkeep
git commit -m "Add GitHub release staging helper"
git branch -M main
git remote add origin https://github.com/YOUR_NAME/YOUR_REPO.git
git push -u origin main
```

3. Create a GitHub token with permission to write repository contents, then set
   it only in your local PowerShell session:

```powershell
$env:GITHUB_TOKEN = "YOUR_TOKEN"
```

## Upload payload files to a release

After you put files in `payload/`, run:

```powershell
.\scripts\Publish-GitHubRelease.ps1 -Owner shiver1514 -Repo cxmt-releases
```

The script creates a `.tar` archive, splits it into release-safe parts when
needed, creates a prerelease tag like `temp-20260509-153000`, and uploads the
archive parts plus a manifest.

Public download URL pattern:

```text
https://github.com/shiver1514/cxmt-releases/releases
```

## Add another folder to an existing release

Use the existing release tag, a source folder that contains only the new files,
and a unique archive label:

```powershell
.\scripts\Publish-GitHubRelease.ps1 -Owner shiver1514 -Repo cxmt-releases -Tag temp-20260509-131032 -SourcePath ".\payload\aidi" -ArchiveLabel aidi
```

This creates additional assets such as:

```text
cxmt-releases-temp-20260509-131032-aidi.tar.part001
manifest-aidi.json
```

Existing assets with different names stay in the release. If you reuse the same
`-ArchiveLabel`, assets with that same label are replaced.

## Restore later

Download all `.partNNN` files and `manifest.json` from the release, then run:

```powershell
.\scripts\Restore-ReleaseArchive.ps1 -PartsDirectory "C:\path\to\downloaded-assets" -OutputDirectory "C:\restore-here"
```

If the release contains a single `.tar` file instead of `.partNNN` files, put it
in the same directory and run the same restore command.
