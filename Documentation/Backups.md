# Backups

Still backups use the `.stillbackup` format. A backup contains Environment
files, application and launch-entry relationships, compatibility settings, and
the exact engine and component requirements recorded in its manifest.

Engine binaries, external game libraries, browser cookies, account tokens,
caches, and Windows user documents are excluded. The export preview reports
the included file count and byte count before writing the backup.

## Container format

Format version 4 writes file data in bounded frames instead of loading an
entire Environment into memory. Regular files record their relative paths,
byte counts, permissions, extended attributes, and SHA-256 digests. Dedicated
records preserve symbolic links, hard links, hidden directories, and empty
directories. Still verifies file data while writing and restoring it.

Password-protected backups use versioned PBKDF2-HMAC-SHA256 parameters and a
random salt. Each frame is protected independently with AES-GCM and a unique
nonce. Header data and frame order participate in authentication. Backup
creation fails if the system random source does not complete successfully.

Still can inspect and restore format versions 1 through 3. New backups are
written in format version 4.

## Restore behavior

A restore creates a new managed Environment and remaps its application and
launch-entry relationships to the new prefix. Still verifies the required
engine and component versions before writing files. Prefix materialization and
the complete Library update are journaled so an interrupted restore can either
finish from a committed store document or remove its incomplete files on the
next launch.
