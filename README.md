# pg-backup

[![CI](https://github.com/ym-scripts/pg-backup/actions/workflows/ci.yml/badge.svg)](https://github.com/ym-scripts/pg-backup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Back up a PostgreSQL database on a schedule and restore it with one command.** Backups go to a local folder and, optionally, to S3 or any S3-compatible storage (Cloudflare R2, Backblaze B2, MinIO). Old backups are deleted automatically.

```bash
npx github:ym-scripts/pg-backup --url "$DATABASE_URL" --keep 14 --s3 s3://my-bucket/db
```

It's a single bash script. Every backup is:

- **checked** by reading it back (`pg_restore --list` or `gzip -t`) before it's kept,
- **checksummed** (a `.sha256` file is stored next to it and verified before any restore),
- **written atomically**, so a failed run never leaves a half-written file that looks like a backup,
- **locked**, so two cron runs can't overlap.

## Requirements

- bash 3.2+ (macOS's bash is fine), `gzip`
- PostgreSQL client tools (`pg_dump`, `pg_restore`, `psql`) **at least as new as the server**
  - macOS: `brew install libpq && brew link --force libpq`
  - Debian/Ubuntu: `sudo apt install postgresql-client` (use the [PGDG repo](https://wiki.postgresql.org/wiki/Apt) for newer versions)
- For S3: the [AWS CLI](https://aws.amazon.com/cli/) with credentials (`aws configure`, or the `AWS_*` environment variables)

## Usage

```bash
pg-backup [backup] [options]          # create a backup (default)
pg-backup list [options]              # list backups, oldest first
pg-backup prune [options]             # apply --keep without backing up
pg-backup restore FILE [options]      # restore a local file or s3:// URI
```

Run it without installing:

```bash
npx github:ym-scripts/pg-backup --help
curl -fsSL https://raw.githubusercontent.com/ym-scripts/pg-backup/main/pg-backup.sh | bash -s -- --help
```

Or install it as a command:

```bash
curl -fsSL https://raw.githubusercontent.com/ym-scripts/pg-backup/main/pg-backup.sh -o ~/.local/bin/pg-backup
chmod +x ~/.local/bin/pg-backup
```

### Options

| Option              | Env var              | Default       | Description                                                                                           |
| ------------------- | -------------------- | ------------- | ----------------------------------------------------------------------------------------------------- |
| `-u`, `--url URL`   | `DATABASE_URL`       |               | `postgres://user:pass@host:5432/db?sslmode=require`                                                   |
| `-d`, `--dir DIR`   | `BACKUP_DIR`         | `./backups`   | Local backup folder                                                                                   |
| `-k`, `--keep N`    | `BACKUP_KEEP`        | `7`           | Keep the newest N backups. `0` keeps everything.                                                      |
| `--name NAME`       |                      | database name | File name prefix                                                                                      |
| `--format F`        |                      | `custom`      | `custom` (`pg_dump -Fc`, compressed, selective restore) or `plain` (`.sql.gz`)                        |
| `--s3 URI`          | `BACKUP_S3`          |               | Also upload to `s3://bucket/prefix`                                                                   |
| `--s3-endpoint URL` | `BACKUP_S3_ENDPOINT` |               | Endpoint for S3-compatible storage                                                                    |
| `--s3-only`         |                      |               | Delete the local copy after a successful upload                                                       |
| `--ping URL`        | `BACKUP_PING_URL`    |               | Request `URL` on success and `URL/fail` on failure ([Healthchecks.io](https://healthchecks.io) style) |
| `-y`, `--yes`       |                      |               | `restore`: skip the typed confirmation                                                                |
| `-q`, `--quiet`     |                      |               | Only print errors and the backup path                                                                 |

The connection string is turned into `PG*` environment variables, so the password never appears in the process list. If the URL has no password, `~/.pgpass` is used.

Backups are named `<name>_<UTC timestamp>.dump`, for example `shop_20261027-020000.dump`. The full path is printed on stdout, so you can capture it with `file=$(pg-backup ...)`.

### Exit codes

| Code | Meaning                                                                 |
| ---- | ----------------------------------------------------------------------- |
| `0`  | Success                                                                 |
| `1`  | Backup, upload or restore failed, or the restore was cancelled          |
| `2`  | Usage or setup error (bad option, missing tool, no terminal to confirm) |

## Restoring

```bash
pg-backup list --dir ./backups --url "$DATABASE_URL"
pg-backup restore ./backups/shop_20261027-020000.dump --url "$TARGET_URL"
pg-backup restore s3://my-bucket/db/shop_20261027-020000.dump --url "$TARGET_URL"
```

You'll be asked to type the target database name. Custom-format backups are restored with `pg_restore --clean --if-exists --no-owner --no-privileges`, which drops and recreates the objects in the backup. Plain backups are piped into `psql` and stop at the first error.

**Test your restores.** A backup you've never restored is a hope, not a backup. Restore into a scratch database every so often.

## Scheduling

**cron** (daily at 02:00, keep two weeks, upload to R2):

```cron
0 2 * * * DATABASE_URL='postgres://…' AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… /home/me/.local/bin/pg-backup -q --dir /var/backups/pg --keep 14 --s3 s3://backups/pg --s3-endpoint https://<account>.r2.cloudflarestorage.com --ping https://hc-ping.com/<uuid> >> /var/log/pg-backup.log 2>&1
```

**GitHub Actions:**

```yaml
on:
  schedule: [{ cron: "0 2 * * *" }]
  workflow_dispatch:
jobs:
  backup:
    runs-on: ubuntu-latest
    steps:
      - run: sudo apt-get install -y postgresql-client
      - run: npx -y github:ym-scripts/pg-backup#v0.1.0 --s3-only --s3 s3://my-bucket/db --keep 30
        env:
          DATABASE_URL: ${{ secrets.DATABASE_URL }}
          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          AWS_DEFAULT_REGION: us-east-1
```

## Security notes

- Backups contain all your data. Use a private bucket with encryption at rest, and restrict who can read it.
- Prefer environment variables or a `.env` file with `chmod 600` to putting the URL in your crontab.
- Use a read-only database role for backups if your provider supports one.

## Development

```bash
bash test/run.sh     # 50 checks against fake pg_dump/psql/aws/curl, no database needed
```

CI also runs a real backup and restore against PostgreSQL 17.

## License

[MIT](LICENSE) © Aghogho Meyoron
