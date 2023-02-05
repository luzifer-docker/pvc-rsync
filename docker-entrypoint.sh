#!/usr/local/bin/dumb-init bash
set -euo pipefail

: ${BASE_DIR:=.}                    # Where to create the backup dir
: ${EXCLUDES_FILE:=}                # File containing exclude globs
: ${EXIT_ON_ERROR:=false}           # Exit on backup error (default keep running)
: ${HETZNER_WORKAROUND:=false}      # Hetzner StorageBox needs sftp for symlinks
: ${INTERVAL:=3600}                 # When to backup (3600 = *:00, 1800 = *:00,30)
: ${KEEP_LAST_N:=0}                 # How many backups to keep
: ${LATEST_LINK:=latest}            # How to name the latest link
: ${LOCAL_DIR:=/data}               # Where to find the data to backup
: ${NAME_SCHEMA:=%Y-%m-%d_%H-%M-%S} # How to name backup dirs, make sure to make it sortable when using KEEP_LAST_N, do not use spaces
: ${ONESHOT:=false}                 # Run only once (backup only), set INTERVAL to 1 to execute directly on start
: ${PING_DOWN:=}                    # Send a ping (HTTP GET) to this URL when an exit-error ocurred
: ${PING_MAX_TIME:=5}               # Time in seconds to timeout the ping request
: ${PING_UP:=}                      # Send a ping (HTTP GET) to this URL when backup finished successfully
: ${REMOTE_HOST:=}                  # Where to send the backups
: ${SKIP_RESTORE_ON:=}              # File to check, if exists restore will be skipped
: ${SSH_CONFIG_MOUNT:=~/.ssh-dist}  # Where to search for ~/.ssh contents to copy into ~/.ssh (Secret mountPath)

function cleanup_old_backups() {
  info "Starting cleanup of backups..."

  for backup in $(ssh "${REMOTE_HOST}" -- ls "${BASE_DIR}" | grep -v "${LATEST_LINK}" | sort | head --lines=-${KEEP_LAST_N}); do
    info "Removing backup ${backup}..."
    ssh "${REMOTE_HOST}" -- rm -rf "${BASE_DIR}/${backup}" || {
      error "Failed to delete backup ${backup}"
      return 1
    }
  done

  info "Cleanup finished."
}

function ensure_basedir() {
  info "Ensuring base-dir..."

  ssh "${REMOTE_HOST}" -- mkdir -p "${BASE_DIR}" || {
    error "Failed to create base-dir."
    return 1
  }
}

function error() {
  log E "$@"
}

function exit_error() {
  if [[ -n $PING_DOWN ]]; then
    curl -sS -m ${PING_MAX_TIME} -o /dev/null "${PING_DOWN}"
  fi

  if [[ $EXIT_ON_ERROR == true ]]; then
    fatal "$@"
    return 0
  fi

  error "$@"
}

function fatal() {
  log F "$@"
  exit 1
}

function import_ssh_dir() {
  info "Importing ~/.ssh from ${SSH_CONFIG_MOUNT}"

  mkdir -p ~/.ssh || {
    error "Failed to create ~/.ssh dir."
    return 1
  }

  local sync_src="${SSH_CONFIG_MOUNT}"
  [[ -e $SSH_CONFIG_MOUNT/..data ]] && sync_src="${SSH_CONFIG_MOUNT}/..data" || true

  rsync -a "${sync_src}/" ~/.ssh/
  chown $(id -u) ~/.ssh/*
  chmod 0600 ~/.ssh/*
}

function info() {
  log I "$@"
}

function link_latest() {
  info "Creating latest link..."

  local dest="$1"
  local link="$2"

  if [[ $HETZNER_WORKAROUND == true ]]; then
    echo -e "rm ${link}\nsymlink ${dest} ${link}" | sftp -q "${REMOTE_HOST}" && return 0 || {
      error "Renewing latest-link (sftp)."
      return 1
    }
  fi

  ssh "${REMOTE_HOST}" -- ln -sf "${dest}" "${link}" || {
    error "Renewing latest-link (ssh)."
    return 1
  }
}

function log() {
  local level=$1
  shift
  echo "[$(date +%H:%M:%S)][$level] $@" >&2
}

function main() {
  [[ -n $REMOTE_HOST ]] || fatal "No REMOTE_HOST set"

  if [[ -d $SSH_CONFIG_MOUNT ]]; then
    import_ssh_dir || fatal "Failed importing SSH config."
  fi

  case "${1:-help}" in
  backup)
    while true; do
      sleep $((INTERVAL - $(date +%s) % INTERVAL))
      run_backup || exit_error "Backup failed."

      if [ $KEEP_LAST_N -gt 0 ]; then
        cleanup_old_backups
      fi

      [[ $ONESHOT != true ]] || {
        info "ONESHOT activated, exit now"
        break
      }
    done
    ;;

  restore)
    run_restore || exit_error "Restore failed."
    ;;

  *)
    usage
    fatal "Action ${1:-help} called"
    ;;
  esac
}

function run_backup() {
  local current="$(date +${NAME_SCHEMA})"
  local dest="${BASE_DIR}/${current}"
  local link="${BASE_DIR}/${LATEST_LINK}"

  info "Starting backup..."

  ensure_basedir || {
    error "Failed to ensure base-dir."
    return 1
  }

  info "Synchronizing backup..."
  extra_params=()

  [[ -z $EXCLUDES_FILE ]] || extra_params+=("--exclude-from=${EXCLUDES_FILE}")

  rsync -av --delete \
    "${LOCAL_DIR}/" \
    --link-dest "../${LATEST_LINK}/" \
    "${extra_params[@]}" \
    "${REMOTE_HOST}:${dest}/" || {
    error "Failed to sync backup-dir."
    return 1
  }

  link_latest "${current}" "${link}" || {
    error "Failed to create latest link."
    return 1
  }

  if [[ -n $PING_UP ]]; then
    curl -sS -m ${PING_MAX_TIME} -o /dev/null "${PING_UP}"
  fi

  info "Backup finished."
}

function run_restore() {
  if [[ -n $SKIP_RESTORE_ON ]] && [[ -e $SKIP_RESTORE_ON ]]; then
    info "Check-file ${SKIP_RESTORE_ON} exists, skipping restore."
    return 0
  fi

  local link="${BASE_DIR}/${LATEST_LINK}"

  info "Starting restore..."

  mkdir -p "${LOCAL_DIR}" || {
    error "Failed to ensure local dir..."
    return 1
  }

  rsync -av --delete \
    "${REMOTE_HOST}:${link}/" \
    "${LOCAL_DIR}/" || {
    error "Failed to sync remote data..."
    return 1
  }

  info "Restore finished."
}

function usage() {
  cat >&2 <<EOF
Usage:
  docker run --rm -ti \
    -v /mydata:/data:ro \
    -e REMOTE_HOST=user@host \
    pvc-rsync <backup|restore>
EOF

}

main "$@"
