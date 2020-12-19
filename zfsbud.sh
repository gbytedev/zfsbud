#!/bin/bash

PATH=/usr/bin:/sbin:/bin
timestamp_format="%Y%m%d%H%M%S"
timestamp=$(date "+$timestamp_format")

snapshot_prefix="auto_"
log_file="$HOME/$(basename "$0").log"

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
      echo "ERROR: --send|-s requires a destination pool name as parameter."
      exit 1
    fi
    ;;
  -L | --log-path)
    if [ "$2" ] && [[ $2 != -* ]]; then
      log=1
      log_file=$2
      shift
      shift
    else
      echo "ERROR: --log-path|-L requires a path to the log file."
      exit 1
    fi
    ;;
  -e | --rsh)
    if [ "$2" ] && [[ $2 != -* ]]; then
      remote_shell=$2
      shift
      shift
    else
      echo "ERROR: --rsh|-e requires an argument specifying the remote shell connection."
      exit 1
    fi
    ;;
  -p | --snapshot-prefix)
    if [ "$2" ] && [[ $2 != -* ]]; then
      snapshot_prefix=$2
      shift
      shift
    else
      echo "ERROR: --snapshot-prefix|-p requires a prefix string as argument."
      exit 1
    fi
    ;;
  -h | --help)
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
    ;;
  esac
done

if [ -v log ]; then
  if ! (touch "$log_file"); then
    echo "ERROR: Unable to create log file '$log_file'."
    exit 1
  fi
  exec > >(tee "$log_file") 2>&1
fi

if [ ! -v create ] && [ ! -v remove_old ] && [ ! -v send ]; then
  echo "ERROR: Specify the operation by adding a --create-snapshot|-c, --remove-old|-r, and/or --send|-s flag(s)."
  exit 1
fi

if [ -v destination_pool ] && [[ $destination_pool == */* ]] || [[ $destination_pool == *@* ]]; then
  echo "ERROR: --send|s needs to specify the destination pool name (pool). (Did you provide a dataset instead?)."
  exit 1
fi

if [[ ! $snapshot_prefix =~ ^[A-Za-z0-9_]+$ ]]; then
  echo "ERROR: The snapshot prefix may only contain letters, digits and underscores."
  exit 1
fi

datasets=("$@")

if ((${#datasets[@]} < 1)); then
  echo "ERROR: One or more source datasets must be present as parameters (pool/dataset pool/dataset2 ...)."
  exit 1
fi

for dataset in "${datasets[@]}"; do
  if [[ $dataset == *@* ]] || [[ $dataset != */* ]]; then
    echo "ERROR: Provided parameters need to be source datasets prefixed with the pool name (pool/dataset pool/dataset2 ...)."
    exit 1
  fi

  if ! zfs list -H -o name | grep -qx "$dataset"; then
    echo "ERROR: Source dataset '$dataset' does not exist."
    exit 1
  fi

  if [ -v send ]; then
    dataset_name=${dataset#*/}

    if [ -v remote_shell ]; then
      if [ ! -v initial ] && ! $remote_shell "zfs list -H -o name" | grep -qx "$destination_pool/$dataset_name"; then
        echo "ERROR: Remote destination dataset '$destination_pool/$dataset_name' does not exist. (Did you mean to send an initial stream by passing the --initial|-i flag instead?)"
        exit 1
      fi

      if [ -v initial ] && $remote_shell "zfs list -H -o name" | grep -qx "$destination_pool/$dataset_name"; then
        echo "ERROR: Remote destination dataset '$destination_pool/$dataset_name' must not exist, as it will be created during the initial send. (Did you mean to send an incremental stream by removing the --initial|-i flag instead?)"
        exit 1
      fi
    else
      if [[ ${dataset%/*} == "$destination_pool" ]]; then
        echo "ERROR: Source pool cannot be identical to destination pool on the same machine. (Did you mean to include the --rsh|-e flag to specify a remote connection?)"
        exit 1
      fi

      if [ ! -v initial ] && ! zfs list -H -o name | grep -qx "$destination_pool/$dataset_name"; then
        echo "ERROR: Local destination dataset '$destination_pool/$dataset_name' does not exist. (Did you mean to send an initial stream by passing the --initial|-i flag instead?)"
        exit 1
      fi

      if [ -v initial ] && zfs list -H -o name | grep -qx "$destination_pool/$dataset_name"; then
        echo "ERROR: Local destination dataset '$destination_pool/$dataset_name' must not exist, as it will be created during the initial send. (Did you mean to send an incremental stream by removing the --initial|-i flag instead?)"
        exit 1
      fi
    fi
  fi
done

if [ ! -v send ] && [ -v initial ]; then
  echo "WARNING: The --initial|-i flag will be ignored, as sending was not specified. (Did you mean to include the --send|-s flag?)"
fi

if [ ! -v send ] && [ -v remote_shell ]; then
  echo "WARNING: The --rsh|-e flag will be ignored, as there is no need for specifying a remote shell connection when not sending. (Did you mean to include the --send|-s flag?)"
fi

if [ -v log ] && [ -v verbose ] && [ -v initial ]; then
  echo "WARNING: Verbose logging during the initial send may produce big log files. Consider omitting the --log|-l and --log-path|-L flags or the --verbose|-v flag."
fi

if [ -v remove_old ]; then
  # Get timestamps of 8 daily, 5 weekly (every sunday), 13 monthly (first sunday of every month) and 6 yearly (first sunday of every year) snapshots to be kept
  for i in {0..7}; do ((keep_snapshots[$(date +%Y%m%d -d "-$i day")]++)); done
  for i in {0..4}; do ((keep_snapshots[$(date +%Y%m%d -d "sunday-$((i + 1)) week")]++)); done
  for i in {0..12}; do
    DW=$(($(date +%-W) - $(date -d "$(date -d "$(date +%Y-%m-15) -$i month" +%Y-%m-01)" +%-W)))
    for ((AY = $(date -d "$(date +%Y-%m-15) -$i month" +%Y); AY < $(date +%Y); AY++)); do
      ((DW += $(date -d "$AY"-12-31 +%W)))
    done
    ((keep_snapshots[$(date +%Y%m%d -d "sunday-$DW weeks")]++))
  done
  for i in {0..5}; do
    DW=$(date +%-W)
    for ((AY = $(($(date +%Y) - i)); AY < $(date +%Y); AY++)); do
      ((DW += $(date -d "$AY"-12-31 +%W)))
    done
    ((keep_snapshots[$(date +%Y%m%d -d "sunday-$DW weeks")]++))
  done
fi

for dataset in "${datasets[@]}"; do
  echo
  echo "*** Processing dataset $dataset. ***"
  echo

  dataset_name=${dataset#*/}
  source_pool=${dataset%/*}

  source_snapshots=($(zfs list -H -o name -t snapshot | grep "$source_pool/$dataset_name@"))

  if [ -v send ] && [ ! -v create ] && ((${#source_snapshots[@]} < 1)); then
    echo "No source snapshots of dataset $dataset_name found. Use the --create-snapshot|-c flag to create a snapshot."
    continue
  fi

  if [ -v send ] && [ ! -v initial ]; then
    if [ -v remote_shell ]; then
      destination_snapshots=($($remote_shell "zfs list -H -o name -t snapshot | grep $destination_pool/$dataset_name@"))
    else
      destination_snapshots=($(zfs list -H -o name -t snapshot | grep "$destination_pool/$dataset_name@"))
    fi

    for destination_snapshot in "${destination_snapshots[@]}"; do
      for source_snapshot in "${source_snapshots[@]}"; do
        if [[ "${source_snapshot#*/}" == "${destination_snapshot#*/}" ]]; then
          last_snapshot_common=${source_snapshot#*/}
        fi
      done
    done

    if [ ! -v last_snapshot_common ]; then
      echo "No common snapshot found between source and destination. Add the --initial|-i flag to clone the snapshots to the destination."
      continue
    fi
  fi

  # Create a new source snapshot.
  if [ -v create ]; then
    new_snapshot="$source_pool/$dataset_name@$snapshot_prefix$timestamp"
    echo "Creating source snapshot: $new_snapshot"
    if [ ! -v dry_run ]; then
      if ! (zfs snapshot "$new_snapshot"); then
        echo "Snapshot '$new_snapshot' could not be created on source dataset '$dataset'."
        continue
      fi
    fi
    source_snapshots+=("$new_snapshot")
  fi

  # Rotate (selectively remove) old source snapshots.
  if [ -v remove_old ]; then
    for i in "${!source_snapshots[@]}"; do
      # Remove all snapshots prefixed accordingly and not matching the
      # keep_snapshots pattern; always keep the most recent snapshot and the last
      # common snapshot.
      if [[ "${source_snapshots[i]}" == *"@$snapshot_prefix"* ]] \
      && [[ "${!keep_snapshots[*]}" != *"${source_snapshots[i]: -${#timestamp}:8}"* ]] \
      && [[ "${source_snapshots[i]}" != "${source_snapshots[-1]}" ]] ; then
        if [ -z "$last_snapshot_common" ] \
        || [[ "${source_snapshots[i]}" != "$source_pool/$last_snapshot_common" ]] ; then
          echo "Deleting source snapshot: ${source_snapshots[i]}"
          if [ ! -v dry_run ]; then
            zfs destroy -f "${source_snapshots[i]}"
          fi
          unset "source_snapshots[i]"
        fi
      fi
    done
    source_snapshots=("${source_snapshots[@]}")
  fi

  if [ -v send ]; then

    # Initial send.

    if [ -v initial ]; then
      first_snapshot_source=${source_snapshots[0]}
      echo "Initial source snapshot: $first_snapshot_source"

      echo "Sending initial snapshot to destination..."
      if [ ! -v dry_run ]; then
        if [ -v remote_shell ]; then
          if zfs send -w$verbose "$first_snapshot_source" | $remote_shell "zfs recv -Fu $destination_pool/$dataset_name"; then
            echo "Initial snapshot has been sent."
          fi
        else
          if zfs send -w$verbose "$first_snapshot_source" | zfs recv -Fu "$destination_pool/$dataset_name"; then
            echo "Initial snapshot has been sent."
          fi
        fi
      else
        # Simulate a successful send for dry run initial send.
        destination_snapshots+=("$first_snapshot_source")
      fi
      last_snapshot_common+="${first_snapshot_source#*/}"
    fi

    last_snapshot_source=${source_snapshots[-1]}
    echo "Most recent source snapshot: $last_snapshot_source"

    if [[ ${last_snapshot_source#*/} == "$last_snapshot_common" ]]; then
      echo "Most recent source snapshot '$last_snapshot_common' exists on destination; skipping incremental sending."
      continue
    fi
    echo "Most recent common snapshot: $last_snapshot_common"

    echo "Sending incremental changes to destination..."
    if [ ! -v dry_run ]; then
      if [ -v remote_shell ]; then
        if zfs send -wR$verbose -I "$source_pool/$last_snapshot_common" "$last_snapshot_source" | $remote_shell "zfs recv -Fdu $destination_pool"; then
          echo "Incremental changes have been sent."
        fi
      else
        if zfs send -wR$verbose -I "$source_pool/$last_snapshot_common" "$last_snapshot_source" | zfs recv -Fdu "$destination_pool"; then
          echo "Incremental changes have been sent."
        fi
      fi
    fi
  fi
done

if [ -v dry_run ]; then
  echo "No changes have been made. To make changes, remove the --dry-run|-d flag."
fi
