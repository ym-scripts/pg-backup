#!/usr/bin/env bash
#
# pg-backup: back up a PostgreSQL database to local files and/or S3, with
# retention, checksums, locking and an optional health-check ping.
# https://github.com/ym-scripts/pg-backup
#
# Copyright (c) 2026 Aghogho Meyoron. MIT License.

set -euo pipefail

VERSION="0.1.0"
CMD="${PG_BACKUP_CMD:-pg-backup}"

usage() {
    cat <<USAGE
pg-backup $VERSION: back up and restore a PostgreSQL database.

Usage:
  $CMD [backup] [options]          Create a backup (the default command)
  $CMD list [options]              List backups, oldest first
  $CMD prune [options]             Apply --keep without taking a backup
  $CMD restore FILE [options]      Restore FILE (local path or s3://...) into --url

Options:                                                     [environment]
  -u, --url URL           postgres://user:pass@host:5432/db  [DATABASE_URL]
  -d, --dir DIR           Local backup directory             [BACKUP_DIR]  default: ./backups
  -k, --keep N            Keep the newest N backups, 0 = all [BACKUP_KEEP] default: 7
      --name NAME         File name prefix                   default: database name
      --format F          custom (pg_dump -Fc) or plain (.sql.gz)        default: custom
      --s3 URI            Also upload to s3://bucket/prefix  [BACKUP_S3]
      --s3-endpoint URL   S3-compatible endpoint (R2, B2, MinIO) [BACKUP_S3_ENDPOINT]
      --s3-only           Delete the local copy after uploading
      --ping URL          GET URL on success, URL/fail on failure [BACKUP_PING_URL]
  -y, --yes               restore: don't ask for confirmation
  -q, --quiet             Only print errors and the backup path
  -v, --version           Print the version
  -h, --help              Show this help

Exit codes: 0 success, 1 backup/restore failed, 2 usage or setup error.
USAGE
}

# ---------- settings ----------
COMMAND="" FILE=""
URL="${DATABASE_URL:-}"
DIR="${BACKUP_DIR:-./backups}"
KEEP="${BACKUP_KEEP:-7}"
NAME=""
FORMAT="custom"
S3="${BACKUP_S3:-}"
S3_ENDPOINT="${BACKUP_S3_ENDPOINT:-}"
S3_ONLY=false
PING="${BACKUP_PING_URL:-}"
YES=false
QUIET=false

die()       { echo "✖ $*" >&2; exit 1; }
die_usage() { echo "✖ $*" >&2; echo "  See: $CMD --help" >&2; exit 2; }
log()       { [ "$QUIET" = true ] || echo "$*" >&2; }
need_val()  { [ $# -ge 2 ] && [ -n "$2" ] || die_usage "$1 needs a value"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --*=*) set -- "${1%%=*}" "${1#*=}" "${@:2}"; continue ;;
        -u|--url)       need_val "$@"; URL="$2"; shift ;;
        -d|--dir)       need_val "$@"; DIR="$2"; shift ;;
        -k|--keep)      need_val "$@"; KEEP="$2"; shift ;;
        --name)         need_val "$@"; NAME="$2"; shift ;;
        --format)       need_val "$@"; FORMAT="$2"; shift ;;
        --s3)           need_val "$@"; S3="$2"; shift ;;
        --s3-endpoint)  need_val "$@"; S3_ENDPOINT="$2"; shift ;;
        --s3-only)      S3_ONLY=true ;;
        --ping)         need_val "$@"; PING="$2"; shift ;;
        -y|--yes)       YES=true ;;
        -q|--quiet)     QUIET=true ;;
        -v|--version)   echo "$VERSION"; exit 0 ;;
        -h|--help|help) usage; exit 0 ;;
        -*)             die_usage "Unknown option: $1" ;;
        *)
            if [ -z "$COMMAND" ]; then
                case "$1" in
                    backup|list|prune|restore) COMMAND="$1" ;;
                    *) die_usage "Unknown command: $1" ;;
                esac
            elif [ "$COMMAND" = restore ] && [ -z "$FILE" ]; then
                FILE="$1"
            else
                die_usage "Unexpected argument: $1"
            fi ;;
    esac
    shift
done
COMMAND="${COMMAND:-backup}"
S3="${S3%/}"

case "$KEEP" in ''|*[!0-9]*) die_usage "--keep must be a number (0 keeps everything)" ;; esac
case "$S3" in ''|s3://?*) ;; *) die_usage "--s3 must look like s3://bucket/prefix" ;; esac
[ "$S3_ONLY" = false ] || [ -n "$S3" ] || die_usage "--s3-only needs --s3"
case "$NAME" in */*) die_usage "--name can't contain /" ;; esac

# ---------- helpers ----------
urldecode() { local s="${1//\\/\\\\}"; printf '%b' "${s//%/\\x}"; }

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

aws_s3() {
    local a=()
    [ -n "$S3_ENDPOINT" ] && a=(--endpoint-url "$S3_ENDPOINT")
    aws "${a[@]+"${a[@]}"}" s3 "$@"
}

ping_url() { [ -z "$PING" ] || curl -fsS -m 10 --retry 3 -o /dev/null "$1" || log "▲ health-check ping failed: $1"; }

# Removes a backup and its checksum from the local directory.
remove_local() { rm -f -- "${DIR:?}/${1:?}" "${DIR:?}/${1:?}.sha256"; }

confirm_restore() {
    [ "$YES" = true ] && return 0
    # [ -r /dev/tty ] passes even without a controlling terminal, so try to open it.
    { exec 3</dev/tty; } 2>/dev/null || die_usage "No terminal to confirm on. Pass --yes to restore non-interactively."
    echo "This replaces objects in $(db_label) with the contents of $(basename "$FILE")." >&2
    printf 'Type the database name (%s) to continue: ' "$DB_NAME" >&2
    local answer
    IFS= read -r answer <&3 || answer=""
    exec 3<&-
    [ "$answer" = "$DB_NAME" ] || die "Cancelled. Nothing was changed."
}

# ---------- database-specific ----------
DB_EXTS="dump sql.gz"

parse_url() {
    local re='^postgres(ql)?://(([^:@/]*)(:([^@/]*))?@)?(\[[^]/]+\]|[^:/?]+)(:([0-9]+))?/([^?]+)(\?(.*))?$'
    [[ "$URL" =~ $re ]] || die_usage "URL must look like postgres://user:pass@host:5432/dbname"
    export PGUSER PGPASSWORD PGHOST PGPORT PGDATABASE PGSSLMODE PGAPPNAME=pg-backup
    PGUSER=$(urldecode "${BASH_REMATCH[3]}")
    PGPASSWORD=$(urldecode "${BASH_REMATCH[5]}")
    PGHOST="${BASH_REMATCH[6]}"; PGHOST="${PGHOST#[}"; PGHOST="${PGHOST%]}"
    PGPORT="${BASH_REMATCH[8]:-5432}"
    PGDATABASE=$(urldecode "${BASH_REMATCH[9]}")
    local query="${BASH_REMATCH[11]}"
    PGSSLMODE="prefer"
    if [[ "$query" =~ (^|&)sslmode=([^&]*) ]]; then PGSSLMODE="${BASH_REMATCH[2]}"; fi
    [ -n "$PGPASSWORD" ] || unset PGPASSWORD   # fall back to ~/.pgpass
    DB_NAME="$PGDATABASE"
}

db_label() { echo "${PGUSER:+$PGUSER@}$PGHOST:$PGPORT/$PGDATABASE"; }

check_tools() {
    local t
    for t in pg_dump pg_restore psql gzip; do
        command -v "$t" >/dev/null 2>&1 || die_usage "$t not found. Install the PostgreSQL client tools (macOS: brew install libpq && brew link --force libpq)."
    done
}

db_ext() {
    case "$FORMAT" in
        custom) echo dump ;;
        plain)  echo sql.gz ;;
        *) die_usage "--format must be custom or plain" ;;
    esac
}

# Writes a dump of the database to $1 and checks it can be read back.
db_dump() {
    if [ "$FORMAT" = custom ]; then
        pg_dump -Fc -f "$1" && pg_restore --list "$1" >/dev/null
    else
        pg_dump --no-owner --no-privileges | gzip -c >"$1" && gzip -t "$1"
    fi
}

db_restore() {
    case "$1" in
        *.dump)   pg_restore --clean --if-exists --no-owner --no-privileges -d "$PGDATABASE" "$1" ;;
        *.sql.gz) gzip -dc "$1" | psql -X -q -v ON_ERROR_STOP=1 ;;
        *.sql)    psql -X -q -v ON_ERROR_STOP=1 -f "$1" ;;
        *) die_usage "Don't know how to restore $1 (expected .dump, .sql.gz or .sql)" ;;
    esac
}
db_cleanup() { :; }
# ---------- end database-specific ----------

# Backups for $NAME in $DIR, oldest first (timestamps sort lexically).
local_backups() {
    local ext f
    [ -d "$DIR" ] || return 0
    for ext in $DB_EXTS; do
        for f in "$DIR/${NAME:-*}"_[0-9]*-[0-9]*."$ext"; do
            [ -e "$f" ] && basename "$f"
        done
    done | awk -F_ '{print $NF "\t" $0}' | sort | cut -f2-
}

s3_backups() {
    local ext name
    aws_s3 ls "$S3/${NAME}" 2>/dev/null | awk '{print $4}' | while IFS= read -r name; do
        for ext in $DB_EXTS; do
            case "$name" in *_[0-9]*-[0-9]*."$ext") echo "$name" ;; esac
        done
    done | awk -F_ '{print $NF "\t" $0}' | sort | cut -f2-
}

# Prints all but the newest $KEEP lines of stdin.
older_than_keep() {
    local all n
    all=$(cat); n=$(printf '%s' "$all" | grep -c . || true)
    [ "$n" -gt "$KEEP" ] || return 0
    printf '%s\n' "$all" | head -n $((n - KEEP))
}

prune() {
    [ "$KEEP" -gt 0 ] || return 0
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        remove_local "$f" && log "  pruned $f"
    done < <(local_backups | older_than_keep)
    [ -n "$S3" ] || return 0
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        aws_s3 rm --only-show-errors "$S3/$f" && { aws_s3 rm --only-show-errors "$S3/$f.sha256" || true; } && log "  pruned $S3/$f"
    done < <(s3_backups | older_than_keep)
}

LOCK=""
TMP=""
cleanup() {
    [ -z "$LOCK" ] || rmdir "$LOCK" 2>/dev/null || true
    [ -z "$TMP" ] || rm -rf -- "${TMP:?}"
    db_cleanup
}
trap cleanup EXIT

cmd_backup() {
    [ -n "$URL" ] || die_usage "No database. Pass --url or set DATABASE_URL."
    parse_url; check_tools
    [ -z "$S3" ] || command -v aws >/dev/null 2>&1 || die_usage "aws CLI not found (needed for --s3)."
    NAME="${NAME:-$DB_NAME}"
    local ext file part t0=$SECONDS
    ext=$(db_ext)
    mkdir -p "$DIR"
    mkdir "$DIR/.$NAME.lock" 2>/dev/null || die "Another backup of $NAME is running (remove $DIR/.$NAME.lock if it isn't)."
    LOCK="$DIR/.$NAME.lock"

    file="${NAME}_$(date -u +%Y%m%d-%H%M%S).$ext"
    part=".$file.partial"
    log "Backing up $(db_label) → $DIR/$file"
    if ! db_dump "$DIR/$part"; then
        remove_local "$part"
        ping_url "$PING/fail"
        die "Backup failed. Nothing was written."
    fi
    mv "$DIR/$part" "$DIR/$file"
    (cd "$DIR" && sha256 "$file" >"$file.sha256")
    log "  ✔ $(du -h "$DIR/$file" | cut -f1 | tr -d ' ') in $((SECONDS - t0))s"

    if [ -n "$S3" ]; then
        if aws_s3 cp --only-show-errors "$DIR/$file" "$S3/$file" && aws_s3 cp --only-show-errors "$DIR/$file.sha256" "$S3/$file.sha256"; then
            log "  ✔ uploaded to $S3/$file"
            [ "$S3_ONLY" = false ] || remove_local "$file"
        else
            ping_url "$PING/fail"
            die "Upload to $S3 failed. The local backup was kept at $DIR/$file"
        fi
    fi

    prune
    ping_url "$PING"
    if [ "$S3_ONLY" = true ]; then echo "$S3/$file"; else echo "$DIR/$file"; fi
}

cmd_list() {
    if [ -z "$NAME" ] && [ -n "$URL" ]; then parse_url; NAME="$DB_NAME"; fi
    local f
    log "Local ($DIR):"
    while IFS= read -r f; do
        [ -n "$f" ] && printf '  %-8s %s\n' "$(du -h "$DIR/$f" | cut -f1 | tr -d ' ')" "$DIR/$f"
    done < <(local_backups)
    if [ -n "$S3" ]; then
        log "S3 ($S3):"
        s3_backups | sed "s|^|  $S3/|"
    fi
    return 0
}

cmd_prune() {
    if [ -z "$NAME" ]; then
        [ -n "$URL" ] || die_usage "Pass --name or --url so prune knows which backups to keep."
        parse_url; NAME="$DB_NAME"
    fi
    [ -z "$S3" ] || command -v aws >/dev/null 2>&1 || die_usage "aws CLI not found (needed for --s3)."
    log "Keeping the newest $KEEP backups of $NAME"
    prune
}

cmd_restore() {
    [ -n "$FILE" ] || die_usage "Which backup? $CMD restore FILE --url URL"
    [ -n "$URL" ] || die_usage "No target database. Pass --url or set DATABASE_URL."
    parse_url; check_tools

    TMP=$(mktemp -d)
    case "$FILE" in
        s3://*)
            command -v aws >/dev/null 2>&1 || die_usage "aws CLI not found (needed for s3:// files)."
            log "Downloading $FILE"
            aws_s3 cp --only-show-errors "$FILE" "$TMP/" || die "Could not download $FILE"
            aws_s3 cp --only-show-errors "$FILE.sha256" "$TMP/" 2>/dev/null || true
            FILE="$TMP/$(basename "$FILE")" ;;
        *) [ -f "$FILE" ] || die_usage "No such file: $FILE" ;;
    esac

    if [ -f "$FILE.sha256" ]; then
        (cd "$(dirname "$FILE")" && sha256 -c "$(basename "$FILE").sha256" >/dev/null 2>&1) || die "Checksum mismatch for $FILE. The file is corrupt."
        log "  ✔ checksum OK"
    fi

    confirm_restore
    log "Restoring $(basename "$FILE") → $(db_label)"
    db_restore "$FILE" || die "Restore finished with errors (see above). Some objects may not have been restored."
    log "  ✔ restored"
}

"cmd_$COMMAND"
