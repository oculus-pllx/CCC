# Project Git Import Design

Date: 2026-05-22
Status: Approved design sections, pending implementation plan

## Goal

Add Git repository import and update actions to the Container Code Companion
Projects page so users can clone projects into the managed Projects directory
and pull fast-forward updates for existing Git projects.

## Scope

The first version supports:

- Generic Git SSH and HTTPS remotes, not GitHub-only remotes.
- Clone/import from the Projects page into `~/projects`.
- Pulling latest fast-forward changes for an existing managed Git project.
- Existing workstation Git authentication:
  - SSH keys for SSH remotes.
  - Existing HTTPS Git credentials for HTTPS remotes.
- Helpful authentication guidance for GitHub SSH and HTTPS failures.

The first version does not include:

- PAT or token entry/storage in CCC.
- Credential embedding in HTTPS remote URLs.
- Arbitrary clone destinations outside the managed Projects directory.
- Arbitrary pull paths outside managed Projects entries.
- GUI merge conflict resolution or non-fast-forward pull behavior.

## UX

The Projects page should add a Clone Repository area above the project list.

Clone fields:

- Repository URL
- Optional project/folder name

Clone action:

- `Clone`

Clone behavior:

- A blank project name derives the folder name from the remote repository name.
- The clone destination is `~/projects/<project-name>`.
- Existing project destinations are rejected instead of overwritten.

Existing project entries should show a `Pull Latest` action only when CCC detects
that the project path is a Git repository. Clone and pull command results should
appear in a Projects output area.

## Backend

Use the existing `/api/project` and `RunProjectOperation` path rather than
creating a separate Git subsystem.

### Clone

New project operation:

```json
{
  "operation": "clone",
  "remote": "git@github.com:owner/repo.git",
  "name": "optional-project-name"
}
```

Clone behavior:

- Accept supported SSH and HTTPS Git remote forms.
- Reject remote URLs that include credential material.
- Validate or derive a safe project name.
- Reject an existing `~/projects/<name>` destination.
- Run `git clone <remote> <target>` as the workstation user.

Supported remote forms for the first version:

- HTTPS: `https://host/owner/repo.git`
- SSH URL: `ssh://git@host/owner/repo.git`
- SCP-style SSH: `git@github.com:owner/repo.git`

### Pull

New project operation:

```json
{
  "operation": "pull",
  "name": "existing-project"
}
```

Pull behavior:

- Resolve the project only through the managed Projects root.
- Verify the selected project path is a Git worktree.
- Run `git pull --ff-only` in the project directory.
- Report non-fast-forward or local-change failures without trying a merge.

## Project Metadata

Project listing should include Git state needed by the UI:

- whether the project is a Git repository
- optionally current branch and remote URL when available cheaply

No credential material should be returned to the browser. If a stored remote is
credentialed despite validation elsewhere, it should be sanitized before UI
output.

## Error Handling

- SSH authentication failures for GitHub SSH remotes should direct users to the
  existing GitHub SSH key workflow.
- HTTPS authentication failures should explain that the host needs HTTPS Git
  credentials configured or the user should use SSH.
- Generic Git failures should return sanitized command output.
- Unsafe remotes, unsafe project names, and clone target collisions should fail
  before command execution.

## Security Boundaries

- Do not accept arbitrary shell fragments through remote inputs.
- Do not add PAT/token UI fields in this version.
- Do not store HTTPS credentials or credentialed remotes.
- Do not clone outside `~/projects`.
- Do not pull from arbitrary paths outside managed Projects entries.
- Do not echo credential material from a pasted remote into logs or browser
  output.

## Verification

Automated coverage should include:

- project-name derivation for SSH and HTTPS remotes
- unsafe or credentialed remote rejection
- clone target collision handling
- pull rejection for non-Git projects
- the `git pull --ff-only` execution path
- `/api/project` server acceptance for clone and pull payloads
- Projects page static/UI checks for Clone Repository and Pull Latest controls

Manual verification should include:

- clone a public HTTPS repository
- clone a GitHub SSH repository after SSH key registration
- pull a project with a fast-forward update
- inspect inaccessible SSH and private HTTPS auth failure messages
