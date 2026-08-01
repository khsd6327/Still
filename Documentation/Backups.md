# Backups

Still backups use the `.stillbackup` format. A backup contains Environment
files, application and launch-entry relationships, compatibility settings, and
the exact engine and component requirements recorded in its manifest.

Engine binaries, external game libraries, browser cookies, account tokens,
caches, and Windows user documents are excluded. The export preview reports
the included file count and byte count before writing the backup.

## Container format

Format version 2 writes file data in bounded frames instead of loading an
entire Environment into memory. Each file record includes its relative path,
byte count, permissions, and SHA-256 digest. Still verifies those values while
writing and restoring the file.

Password-protected backups use versioned PBKDF2-HMAC-SHA256 parameters and a
random salt. Each frame is protected independently with AES-GCM and a unique
nonce. Header data and frame order participate in authentication. Backup
creation fails if the system random source does not complete successfully.

Still can inspect and restore format version 1 backups. New backups are always
written in format version 2.
