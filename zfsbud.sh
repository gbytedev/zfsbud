#!/usr/bin/env bash

PATH=/usr/bin:/sbin:/bin
readonly timestamp_format="%Y%m%d%H%M%S"
readonly timestamp=$(date "+$timestamp_format")

snapshot_prefix="zfsbud_"
log_file="$HOME/$(basename "$0").log"

keep_timestamps=()

msg() { echo "$*" 1>&2; }
warn() { msg "WARNING: $*"; }
die() { msg "ERROR: $*"; exit 1; }

help() {
    echo "Usage: $(basename "$0") [OPTION]... SOURCE_POOL/DATASET [SOURCE_POOL/DATASET2...]"
    echo
    echo " -s, --send <destination_pool_name>   send source dataset incrementally to destination"
    echo " -i, --initial                        initially clone source dataset to destination (requires --send)"
    echo " -e, --rsh <'ssh user@server -p22'>   send to remote destination by providing ssh connection string (requires --send)"
    echo " -c, --create-snapshot                create a timestamped snapshot on source"
    echo " -r, --remove-old                     remove all but the most recent, the last common (if sending), 8 daily, 5 weekly, 13 monthly and 6 yearly source snapshots"
    echo " -d, --dry-run                        show output without making actual changes"
    echo " -p, --snapshot-prefix <prefix>       use a snapshot prefix other than '_auto'"
    echo " -v, --verbose                        increase verbosity"
    echo " -l, --log                            log to user's home directory"
    echo " -L, --log-path </path/to/file>       provide path to log file (implies --log)"
    echo " -h, --help                           show this help"
    exit 0
}

for arg in "$@"; do
  case $arg in
  -c | --create-snapshot)
    create=1
    shift
    ;;
  -r | --remove-old)
    remove_old=1
    shift
    ;;
  -i | --initial)
    initial=1
    shift
    ;;
  -d | --dry-run)
    dry_run=1
    shift
    ;;
  -v | --verbose)
    verbose="v"
    shift
    ;;
  -l | --log)
    log=1
    shift
    ;;
  -s | --send)
    if [ "$2" ] && [[ $2 != -* ]]; then
      send=1
      destination_pool=$2
      shift
      shift
    else
      die "--send|-s requires a destination pool name as parameter."
    fi
    ;;
  -L | --log-path)
    if [ "$2" ] && [[ $2 != -* ]]; then
      log=1
      log_file=$2
      shift
      shift
    else
      die "--log-path|-L requires a path to the log file."
    fi
    ;;
  -e | --rsh)
    if [ "$2" ] && [[ $2 != -* ]]; then
      remote_shell=$2
      shift
      shift
    else
      die "--rsh|-e requires an argument specifying the remote shell connection."
    fi
    ;;
  -p | --snapshot-prefix)
    if [ "$2" ] && [[ $2 != -* ]]; then
      snapshot_prefix=$2
      shift
      shift
    else
      die "--snapshot-prefix|-p requires a prefix string as argument."
    fi
    ;;
  -h | --help) help ;;
  -?*)
    die "Unknown option: $1" ;;
  esac
done

validate_dataset() {
  local dataset="$1"

  # Validate dataset name.

  [[ $dataset == *@* ]] || [[ $dataset != */* ]] && die "Provided parameters need to be source datasets prefixed with the pool name (pool/dataset pool/dataset2 ...)."

  ! zfs list -H -o name | grep -qx "$dataset" && die "Source dataset '$dataset' does not exist."

  # Validate sending the dataset dataset.

  [ ! -v send ] && return

  dataset_name=${dataset#*/}

  if [ -v remote_shell ]; then
    if [ ! -v initial ] && ! $remote_shell "zfs list -H -o name" | grep -qx "$destination_pool/$dataset_name"; then
      die "Remote destination dataset '$destination_pool/$dataset_name' does not exist. (Did you mean to send an initial stream by passing the --initial|-i flag instead?)"
    fi
    if [ -v initial ] && $remote_shell "zfs list -H -o name" | grep -qx "$destination_pool/$dataset_name"; then
      die "Remote destination dataset '$destination_pool/$dataset_name' must not exist, as it will be created during the initial send. (Did you mean to send an incremental stream by removing the --initial|-i flag instead?)"
    fi
  else
    [[ ${dataset%/*} == "$destination_pool" ]] && die "Source pool cannot be identical to destination pool on the same machine. (Did you mean to include the --rsh|-e flag to specify a remote connection?)"
    if [ ! -v initial ] && ! zfs list -H -o name | grep -qx "$destination_pool/$dataset_name"; then
      die "Local destination dataset '$destination_pool/$dataset_name' does not exist. (Did you mean to send an initial stream by passing the --initial|-i flag instead?)"
    fi
    if [ -v initial ] && zfs list -H -o name | grep -qx "$destination_pool/$dataset_name"; then
      die "Local destination dataset '$destination_pool/$dataset_name' must not exist, as it will be created during the initial send. (Did you mean to send an incremental stream by removing the --initial|-i flag instead?)"
    fi
  fi
}

# Get timestamps of 8 daily, 5 weekly (every sunday), 13 monthly (first sunday
# of every month) and 6 yearly (first sunday of every year) snapshots to be kept.
set_timestamps_to_keep() {
  (( ${#keep_timestamps[@]} )) && return 0 # Perform function once.

  for i in {0..7}; do ((keep_timestamps[$(date +%Y%m%d -d "-$i day")]++)); done
  for i in {0..4}; do ((keep_timestamps[$(date +%Y%m%d -d "sunday-$((i + 1)) week")]++)); done
  for i in {0..12}; do
    DW=$(($(date +%-W) - $(date -d "$(date -d "$(date +%Y-%m-15) -$i month" +%Y-%m-01)" +%-W)))
    for ((AY = $(date -d "$(date +%Y-%m-15) -$i month" +%Y); AY < $(date +%Y); AY++)); do
      ((DW += $(date -d "$AY"-12-31 +%W)))
    done
    ((keep_timestamps[$(date +%Y%m%d -d "sunday-$DW weeks")]++))
  done
  for i in {0..5}; do
    DW=$(date +%-W)
    for ((AY = $(($(date +%Y) - i)); AY < $(date +%Y); AY++)); do
      ((DW += $(date -d "$AY"-12-31 +%W)))
    done
    ((keep_timestamps[$(date +%Y%m%d -d "sunday-$DW weeks")]++))
  done
}

get_local_snapshots() {
  echo $(zfs list -H -o name -t snapshot | grep "$1/$2@")
}

get_remote_snapshots() {
  echo $($remote_shell "zfs list -H -o name -t snapshot | grep $1/$2@")
}

set_source_snapshots() {
  (( ${#source_snapshots[@]} )) && return 0 # Perform function once.
  source_snapshots=($(get_local_snapshots "$1" "$2"))
}

set_destination_snapshots() {
  (( ${#destination_snapshots[@]} )) && return 0 # Perform function once.

  if [ -v remote_shell ]; then
    destination_snapshots=($(get_remote_snapshots "$destination_pool" "$1"))
  else
    destination_snapshots=($(get_local_snapshots "$destination_pool" "$1"))
  fi
}

set_common_snapshot() {
  [ -n "$last_snapshot_common" ] && return 0 # Perform function once.

  for destination_snapshot in "${destination_snapshots[@]}"; do
    for source_snapshot in "${source_snapshots[@]}"; do
      [[ "${source_snapshot#*/}" == "${destination_snapshot#*/}" ]] && last_snapshot_common=${source_snapshot#*/}
    done
  done
  [ -n "$last_snapshot_common" ] && return 0 || return 1
}

rotate_snapshots() {
  set_timestamps_to_keep
  for i in "${!source_snapshots[@]}"; do
    # Remove all snapshots prefixed accordingly and not matching the
    # keep_timestamps pattern; always keep the most recent snapshot and the last
    # common snapshot.
    if [[ "${source_snapshots[i]}" == *"@$snapshot_prefix"* ]] \
    && [[ "${!keep_timestamps[*]}" != *"${source_snapshots[i]: -${#timestamp}:8}"* ]] \
    && [[ "${source_snapshots[i]}" != "${source_snapshots[-1]}" ]] ; then
      if [ -z "$last_snapshot_common" ] \
      || [[ "${source_snapshots[i]}" != "$source_pool/$last_snapshot_common" ]] ; then
        msg "Deleting source snapshot: ${source_snapshots[i]}"
        [ ! -v dry_run ] && zfs destroy -f "${source_snapshots[i]}"
        unset "source_snapshots[i]"
      fi
    fi
  done
  source_snapshots=("${source_snapshots[@]}")
}

create_new_snapshot() {
  local new_snapshot="$source_pool/$dataset_name@$snapshot_prefix$timestamp"
  msg "Creating source snapshot: $new_snapshot"
  if [ ! -v dry_run ]; then
    if ! (zfs snapshot "$new_snapshot"); then
      msg "Snapshot '$new_snapshot' could not be created on source dataset '$dataset'."
      return 1
    fi
  fi
  source_snapshots+=("$new_snapshot")
}

send_initial() {
  local first_snapshot_source=${source_snapshots[0]}
  msg "Initial source snapshot: $first_snapshot_source"
  msg "Sending initial snapshot to destination..."
  if [ ! -v dry_run ]; then
    if [ -v remote_shell ]; then
      ! zfs send -w$verbose "$first_snapshot_source" | $remote_shell "zfs recv -Fu $destination_pool/$dataset_name" && return 1
    else
      ! zfs send -w$verbose "$first_snapshot_source" | zfs recv -Fu "$destination_pool/$dataset_name" && return 1
    fi
  else
    # Simulate a successful send for dry run initial send.
    destination_snapshots+=("$first_snapshot_source")
  fi
  msg "Initial snapshot has been sent."
  last_snapshot_common="${first_snapshot_source#*/}"
}

send_incremental() {
  local last_snapshot_source=${source_snapshots[-1]}
  msg "Most recent source snapshot: $last_snapshot_source"
  if [[ ${last_snapshot_source#*/} == "$last_snapshot_common" ]]; then
    msg "Most recent source snapshot '$last_snapshot_common' exists on destination; skipping incremental sending."
    return 1
  fi
  msg "Most recent common snapshot: $last_snapshot_common"
  msg "Sending incremental changes to destination..."
  if [ ! -v dry_run ]; then
    if [ -v remote_shell ]; then
      ! zfs send -wR$verbose -I "$source_pool/$last_snapshot_common" "$last_snapshot_source" | $remote_shell "zfs recv -Fdu $destination_pool" && return 1
    else
      ! zfs send -wR$verbose -I "$source_pool/$last_snapshot_common" "$last_snapshot_source" | zfs recv -Fdu "$destination_pool" && return 1
    fi
  fi
  msg "Incremental changes have been sent."
}

process_dataset() {
  local source_pool=${1%/*}
  local dataset_name=${1#*/}
  source_snapshots=()
  destination_snapshots=()
  last_snapshot_common=""

  msg
  msg "*** Processing dataset $1. ***"
  msg

  set_source_snapshots "$source_pool" "$dataset_name"

  if [ -v send ] && [ ! -v create ] && ((${#source_snapshots[@]} < 1)); then
    msg "No source snapshots of dataset $dataset_name found. Use the --create-snapshot|-c flag to create a snapshot."
    return 1
  fi

  # todo Do not force to recreate dataset if common snapshot is not available?
  if [ -v send ] && [ ! -v initial ] && set_destination_snapshots "$dataset_name" && ! set_common_snapshot; then
    msg "No common snapshot found between source and destination. Add the --initial|-i flag to clone the snapshots to the destination."
    return 1
  fi

  # Create a new source snapshot.
  [ -v create ] && ! create_new_snapshot && return 1

  # Rotate (selectively remove) old source snapshots.
  [ -v remove_old ] && rotate_snapshots

  # Initial send.
  [ -v send ] && [ -v initial ] && ! send_initial && return 1

  # Consecutive send.
  [ -v send ] &&  ! send_incremental && return 1
}

# Start logging if instructed.
if [ -v log ]; then
  ! (touch "$log_file") && die "Unable to create log file '$log_file'."
  exec > >(tee "$log_file") 2>&1
fi

# Require an operation.
[ ! -v create ] && [ ! -v remove_old ] && [ ! -v send ] && die "Specify the operation by adding a --create-snapshot|-c, --remove-old|-r, and/or --send|-s flag(s)."

# Require a correct destination pool name specified for --send.
[ -v destination_pool ] && [[ $destination_pool == */* ]] || [[ $destination_pool == *@* ]] && die "--send|s needs to specify the destination pool name (pool). (Did you provide a dataset instead?)."

# Allow only letters, numbers and underscores for the snapshot prefix.
[[ ! $snapshot_prefix =~ ^[A-Za-z0-9_]+$ ]] && die "The snapshot prefix may only contain letters, digits and underscores."

datasets=("$@")

# Require dataset names as arguments and validate them.
((${#datasets[@]} < 1)) && die "One or more source datasets must be present as parameters (pool/dataset pool/dataset2 ...)."
for dataset in "${datasets[@]}"; do
  validate_dataset "$dataset"
done

# Warn about potentially erroneous options.
[ ! -v send ] && [ -v initial ] && warn "The --initial|-i flag will be ignored, as sending was not specified. (Did you mean to include the --send|-s flag?)"
[ ! -v send ] && [ -v remote_shell ] && warn "The --rsh|-e flag will be ignored, as there is no need for specifying a remote shell connection when not sending. (Did you mean to include the --send|-s flag?)"
[ -v log ] && [ -v verbose ] && [ -v initial ] && warn "Verbose logging during the initial send may produce big log files. Consider omitting the --log|-l and --log-path|-L flags or the --verbose|-v flag."

# Process each dataset.
for dataset in "${datasets[@]}"; do
  process_dataset "$dataset"
done

# Inform about the lack of changes in dry-run mode.
[ -v dry_run ] && msg "No changes have been made. To make changes, remove the --dry-run|-d flag."
