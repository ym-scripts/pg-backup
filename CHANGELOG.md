# Changelog

All notable changes to this project are documented here. This project follows [Semantic Versioning](https://semver.org).

## [0.1.0] - 2026-10-27

### Added

- `backup`, `list`, `prune` and `restore` commands.
- Custom (`pg_dump -Fc`) and plain (`.sql.gz`) formats. Each backup is checked by reading it back before it's kept.
- SHA-256 checksum next to every backup, verified before restoring.
- Retention with `--keep N`, applied locally and on S3.
- Upload to S3 or S3-compatible storage (R2, B2, MinIO) through the `aws` CLI, with an optional `--s3-only`.
- Restore from local files or `s3://` URIs, with a typed confirmation unless `--yes` is passed.
- Lock against overlapping runs, atomic writes, and a health-check ping on success or failure.
