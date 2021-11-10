#!/usr/bin/env bash

PATH=/usr/bin:/sbin:/bin
trap "exit 1" TERM
export TOP_PID=$$
readonly timestamp_format="%Y%m%d%H%M%S"
timestamp=$(date "+$timestamp_format")
readonly timestamp

snapshot_prefix="zfsbud_"
log_file="$HOME/$(basename "$0").log"

keep_timestamps=()
resume="-s"

msg() { echo "$*" 1>&2; }
warn() { msg "WARNING: $*"; }
die() { msg "ERROR: $*"; kill -s TERM $TOP_PID; }

help() {
    echo "Usage: $(basename "$0") [OPTION]... SOURCE/DATASET/PATH [SOURCE/DATASET/PATH2...]"
    echo
    echo " -s, --send <destination_parent_dataset/path> send source dataset incrementally to specified destination"
    echo " -i, --initial                                initially clone source dataset to destination (requires --send)"
    echo " -n, --no-resume                              do not create resumable streams and do not resume streams (requires --send)"
    echo " -e, --rsh <'ssh user@server -p22'>           send to remote destination by providing ssh connection string (requires --send)"
    echo " -c, --create-snapshot [label]                create a timestamped snapshot on source with an optional label"
    echo " -R, --recursive                              send or snapshot dataset recursively along with child datasets (requires --send or --create-snapshot)"
    echo " -r, --remove-old                             remove all but the most recent, the last common (if sending), 8 daily, 5 weekly, 13 monthly and 6 yearly source snapshots"
    echo " -d, --dry-run                                show output without making actual changes"
    echo " -p, --snapshot-prefix <prefix>               use a snapshot prefix other than 'zfsbud_'"
    echo " -v, --verbose                                increase verbosity"
    echo " -l, --log                                    log to user's home directory"
    echo " -L, --log-path </path/to/file>               provide path to log file (implies --log)"
    echo " -h, --help                                   show this help"
    exit 0
}

for arg in "$@"; do
  case $arg in
  -c | --create-snapshot)
    create=1
    if [ "$2" ] && [[ $2 != -* ]] && [[ $2 != */* ]] ; then
      snapshot_label="_$2"
      shift
    fi
    shift
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
  -r | --remove-old)
    remove_old=1
    shift
    ;;
  -s | --send)
    if [ "$2" ] && [[ $2 != -* ]]; then
      send=1
      destination_parent_dataset=$2
      shift
      shift
    else
      die "--send|-s requires a destination dataset name as parameter."
    fi
    ;;
  -i | --initial)
    initial=1
    shift
    ;;
  -R | --recursive)
    recursive_send="-R"
    recursive_create="-r"
    shift
    ;;
  -n | --no-resume)
    unset resume
    shift
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
  -v | --verbose)
    verbose="-v"
    shift
    ;;
  -l | --log)
    log=1
    shift
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
  -d | --dry-run)
    dry_run=1
    shift
    ;;
  -h | --help) help ;;
  -?*)
    die "Invalid option '$1' Try '$(basename "$0") --help' for more information." ;;
  esac
done

config_read_file() {
  (grep -E "^${2}=" -m 1 "${1}" 2>/dev/null || echo "VAR=__UNDEFINED__") | head -n 1 | cut -d '=' -f 2-;
}

config_get() {
  working_dir="$(dirname "$(readlink -f "$0")")"
  val="$(config_read_file $working_dir/zfsbud.conf "${1}")";
  if [ "${val}" = "__UNDEFINED__" ]; then
    val="$(config_read_file $working_dir/default.zfsbud.conf "${1}")";
    if [ "${val}" = "__UNDEFINED__" ]; then
      die "Default configuration file 'default.zfsbud.conf' is missing or corrupt."
    fi
  fi
  printf -- "%s" "${val}";
}

dataset_exists() {
  if [ -v remote_shell ]; then
    $remote_shell "zfs list -H -o name" | grep -qx "$1" && return 0
  else
    zfs list -H -o name | grep -qx "$1" && return 0
  fi
  return 1
}

validate_dataset() {
  local dataset="$1"
  local dataset_name=${dataset##*/}
  unset resume_token

  # Validate dataset name.

  # todo Make it work for pools without datasets?
  [[ $dataset == *@* ]] || [[ $dataset != */* ]] && die "Provided parameters need to be source datasets (source/dataset/path1 source/dataset/path2 ...)."

  ! zfs list -H -o name | grep -qx "$dataset" && die "Source dataset '$dataset' does not exist."

  # Validate sending the dataset.

  [ ! -v send ] && return

  set_resume_token "$destination_parent_dataset/$dataset_name"

  if [ ! -v resume ] && [ -v resume_token ]; then
    die "--no-resume|-n was specified for '$destination_parent_dataset/$dataset_name', but the destination only accepts a resumable stream. (Did you mean to exclude the --no-resume|-n flag? Otherwise you can cancel the transfer by running 'zfs receive -A <destination_dataset/path>' on the destination machine.)"
  fi
  
  if [ ! -v resume_token ] && [ ! -v initial ] && ! dataset_exists "$destination_parent_dataset/$dataset_name"; then
    die "Destination dataset '$destination_parent_dataset/$dataset_name' does not exist. (Did you mean to send an initial stream by passing the --initial|-i flag instead?)"
  fi
  
  if [ ! -v resume_token ] && [ -v initial ] && dataset_exists "$destination_parent_dataset/$dataset_name"; then
    die "Destination dataset '$destination_parent_dataset/$dataset_name' must not exist, as it will be created during the initial send. (Did you mean to send an incremental stream by excluding the --initial|-i flag instead?)"
  fi
}

set_timestamps_to_keep() {
  (( ${#keep_timestamps[@]} )) && return 0 # Perform function once.

  for (( i=0; i<=$(config_get daily)-1; i++ )); do ((keep_timestamps[$(date +%Y%m%d -d "-$i day")]++)); done
  for (( i=0; i<=$(config_get weekly)-1; i++ )); do ((keep_timestamps[$(date +%Y%m%d -d "sunday-$((i + 1)) week")]++)); done
  for (( i=0; i<=$(config_get monthly)-1; i++ )); do
    DW=$(($(date +%-W) - $(date -d "$(date -d "$(date +%Y-%m-15) -$i month" +%Y-%m-01)" +%-W)))
    for ((AY = $(date -d "$(date +%Y-%m-15) -$i month" +%Y); AY < $(date +%Y); AY++)); do
      ((DW += $(date -d "$AY"-12-31 +%W)))
    done
    ((keep_timestamps[$(date +%Y%m%d -d "sunday-$DW weeks")]++))
  done
  for (( i=0; i<=$(config_get yearly)-1; i++ )); do
    DW=$(date +%-W)
    for ((AY = $(($(date +%Y) - i)); AY < $(date +%Y); AY++)); do
      ((DW += $(date -d "$AY"-12-31 +%W)))
    done
    ((keep_timestamps[$(date +%Y%m%d -d "sunday-$DW weeks")]++))
  done
}

get_local_snapshots() {
  zfs list -H -o name -t snapshot | grep "$1@"
}

get_remote_snapshots() {
  $remote_shell "zfs list -H -o name -t snapshot | grep $1@"
}

set_source_snapshots() {
  (( ${#source_snapshots[@]} )) && return 0 # Perform function once.
  mapfile -t source_snapshots < <(get_local_snapshots "$1")
}

set_destination_snapshots() {
  if [ -v remote_shell ]; then
    mapfile -t destination_snapshots < <(get_remote_snapshots "$destination_parent_dataset/$1")
  else
    mapfile -t destination_snapshots < <(get_local_snapshots "$destination_parent_dataset/$1")
  fi
}

set_common_snapshot() {
  for destination_snapshot in "${destination_snapshots[@]}"; do
    for source_snapshot in "${source_snapshots[@]}"; do
      [[ "${source_snapshot#*@}" == "${destination_snapshot#*@}" ]] && last_snapshot_common=${source_snapshot#*@}
    done
  done
  [ -v last_snapshot_common ] && return 0 || return 1
}

set_resume_token() {
  ! dataset_exists "$1" && return 0
  
  local token="-"
  
  if [ -v remote_shell ]; then
    token=$($remote_shell "zfs get -H -o value receive_resume_token $1")
  else
    token=$(zfs get -H -o value receive_resume_token "$1")
  fi
  
  [[ $token ]] && [[ $token != "-" ]] && resume_token=$token
}

rotate_snapshots() {
  set_timestamps_to_keep
  for i in "${!source_snapshots[@]}"; do
    # Remove all snapshots prefixed accordingly and not matching the
    # keep_timestamps pattern; always keep the most recent snapshot and the last
    # common snapshot.
    snapshot_name=${source_snapshots[i]#*"@$snapshot_prefix"}
    if [[ "${source_snapshots[i]}" == *"@$snapshot_prefix"* ]] \
    && [[ "${!keep_timestamps[*]}" != *"${snapshot_name:0:8}"* ]] \
    && [[ "${source_snapshots[i]}" != "${source_snapshots[-1]}" ]] ; then
      if [ ! -v last_snapshot_common ] \
      || [[ "${source_snapshots[i]}" != "$dataset@$last_snapshot_common" ]] ; then
        msg "Deleting source snapshot: ${source_snapshots[i]}"
        [ ! -v dry_run ] && zfs destroy -f "${source_snapshots[i]}"
        unset "source_snapshots[i]"
      fi
    fi
  done
  source_snapshots=("${source_snapshots[@]}")
}

# todo Update messages for recursive snapshots.
create_new_snapshot() {
  local new_snapshot="$dataset@$snapshot_prefix$timestamp$snapshot_label"
  msg "Creating source snapshot: $new_snapshot"
  if [ ! -v dry_run ]; then
    if ! zfs snapshot $recursive_create "$new_snapshot"; then
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
      ! zfs send -w $recursive_send $verbose "$first_snapshot_source" | $remote_shell "zfs recv $resume -F -u $destination_parent_dataset/$dataset_name" && return 1
    else
      ! zfs send -w $recursive_send $verbose "$first_snapshot_source" | zfs recv $resume -F -u "$destination_parent_dataset/$dataset_name" && return 1
    fi
  else
    # Simulate a successful send for dry run initial send.
    destination_snapshots+=("$first_snapshot_source")
  fi
  msg "Initial snapshot has been sent."
  last_snapshot_common="${first_snapshot_source#*@}"
}

send_resume() {
  local pool=${destination_parent_dataset%%/*}

  if [ ! -v dry_run ]; then
    if [ -v remote_shell ]; then
      ! zfs send -w $verbose -t "$resume_token" | $remote_shell "zfs recv $resume -F -d -u $pool" && return 1
    else
      ! zfs send -w $verbose -t "$resume_token" | zfs recv $resume -F -d -u "$pool" && return 1
    fi
  fi
  msg "The resumed transfer has been successfully completed."
}

send_incremental() {
  local last_snapshot_source=${source_snapshots[-1]}
  msg "Most recent source snapshot: ${last_snapshot_source#*@}"

  if [[ ${last_snapshot_source#*@} == "$last_snapshot_common" ]]; then
    msg "Most recent source snapshot '$last_snapshot_common' exists on destination; skipping incremental sending."
    return 1
  fi
  msg "Most recent common snapshot: $last_snapshot_common"
  msg "Sending incremental changes to destination..."
  
  if [ ! -v dry_run ]; then
    if [ -v remote_shell ]; then
      ! zfs send -w $recursive_send $verbose -I "$dataset@$last_snapshot_common" "$last_snapshot_source" | $remote_shell "zfs recv $resume -F -d -u $destination_parent_dataset" && return 1
    else
      ! zfs send -w $recursive_send $verbose -I "$dataset@$last_snapshot_common" "$last_snapshot_source" | zfs recv $resume -F -d -u "$destination_parent_dataset" && return 1
    fi
  fi
  msg "Incremental changes have been sent."
}

function compare_datasets() {
  set_destination_snapshots "$dataset_name" && ! set_common_snapshot && return 1
  return 0
}

function warn_no_common_snapshots() {
  warn "No common snapshot found between source and destination. Add the --initial|-i flag to clone the snapshots to the destination."
}

process_dataset() {
  local dataset="$1"
  local dataset_name=${dataset##*/}
  local source_parent_dataset=${dataset%/$dataset_name*}
  source_snapshots=()
  destination_snapshots=()
  unset last_snapshot_common
  unset resume_token

  msg
  msg "*** Processing dataset $1. ***"
  msg

  set_source_snapshots "$dataset"

  if [ -v send ] && [ ! -v create ] && ((${#source_snapshots[@]} < 1)); then
    warn "No source snapshots of dataset $dataset found. Use the --create-snapshot|-c flag to create a snapshot."
    return 1
  fi

  ### Create a new source snapshot. ###

  [ -v create ] && ! create_new_snapshot && return 1

  ### Rotate (selectively remove) old source snapshots. ###

  [ -v send ] && [ ! -v initial ] && compare_datasets
  [ -v remove_old ] && rotate_snapshots

  ### Send. ###

  [ ! -v send ] && return 0
  
  # Set resume token.
  [ -v resume ] && set_resume_token "$destination_parent_dataset/$dataset_name"

  if [ -v resume_token ]; then
    # Resume send & consecutive send.
    ! send_resume && return 1
    ! compare_datasets && warn_no_common_snapshots && return 1
    ! send_incremental && return 1
  else
    # Initial send & consecutive send.
    ! compare_datasets && [ ! -v initial ] && warn_no_common_snapshots && return 1
    [ -v initial ] && ! send_initial && return 1
    ! send_incremental && return 1
  fi
}

# Start logging if instructed.
if [ -v log ]; then
  ! (touch "$log_file") && die "Unable to create log file '$log_file'."
  exec > >(tee "$log_file") 2>&1
fi

# Require an operation.
[ ! -v create ] && [ ! -v remove_old ] && [ ! -v send ] && die "Specify the operation by adding a --create-snapshot|-c, --remove-old|-r, and/or --send|-s flag(s)."

# Require a correct destination dataset name specified for --send.
[ -v destination_parent_dataset ] && [[ $destination_parent_dataset == *@* ]] && die "--send|s needs to specify the destination dataset name. (Did you provide a snapshot instead?)."

# Allow only letters, numbers and underscores for the snapshot prefix.
[[ ! $snapshot_prefix =~ ^[A-Za-z0-9_]+$ ]] && die "The snapshot prefix may only contain letters, digits and underscores."

# Allow only letters, numbers and underscores for the snapshot label.
[ -v snapshot_label ] && [[ ! $snapshot_label =~ ^[A-Za-z0-9_]+$ ]] && die "The snapshot label may only contain letters, digits and underscores."

datasets=("$@")

# Require dataset names as arguments and validate them.
((${#datasets[@]} < 1)) && die "One or more source datasets must be present as parameters (source/dataset/path1 source/dataset/path2 ...)."
for dataset in "${datasets[@]}"; do
  validate_dataset "$dataset"
done

# Warn about potentially erroneous options.
[ ! -v send ] && [ -v initial ] && warn "The --initial|-i flag will be ignored, as sending was not specified. (Did you mean to include the --send|-s flag?)"
[ ! -v send ] && [ ! -v resume ] && warn "The --no-resume|-n flag will be ignored, as sending was not specified. (Did you mean to include the --send|-s flag?)"
[ ! -v send ] && [ -v remote_shell ] && warn "The --rsh|-e flag will be ignored, as there is no need for specifying a remote shell connection when not sending. (Did you mean to include the --send|-s flag?)"
[ ! -v send ] && [ ! -v create ] && [ -v recursive_send ] && warn "The --recursive|-R flag will be ignored, as sending or creating snapshot was not specified. (Did you mean to include the --send|-s or --create-snapshot|-c flag?)"
[ -v log ] && [ -v verbose ] && [ -v initial ] && warn "Verbose logging during the initial send may produce big log files. Consider excluding the --log|-l and --log-path|-L flags or the --verbose|-v flag."

# Process each dataset.
for dataset in "${datasets[@]}"; do
  process_dataset "$dataset"
done

# Inform about the lack of changes in dry-run mode.
[ -v dry_run ] && msg "No changes have been made. To make changes, remove the --dry-run|-d flag."

exit 0
