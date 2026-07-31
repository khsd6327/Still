# Contributing

Still accepts bug reports and pull requests through GitHub. Gitea is maintained
as a mirror.

## Reporting bugs

Before opening an issue:

1. Confirm that the issue occurs with the current source.
2. Test with a clean bottle when practical.
3. Record the macOS version, engine, graphics backend, application version, and
   exact failure boundary.
4. Remove account details, local paths, credentials, and copyrighted files from
   logs or screenshots.

Use GitHub's private vulnerability reporting for security issues instead of a
public issue.

## Pull requests

1. Keep each pull request focused on one change.
2. Add or update tests for behavior changes.
3. Run `swift test` before submission.
4. Preserve engine neutrality and keep application-specific behavior in
   declarative profiles when possible.
5. Include the source and license for new engines, patches, or dependencies.

No Contributor License Agreement is required. By submitting a contribution,
you agree to license it under the repository's MIT License and any applicable
third-party license for files derived from another project.
