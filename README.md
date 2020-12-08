# zfsbud
ZFS snapshotting, replicating & backup rotating convenience script.

## Introduction
This is a convenience script that helps to manage multiple ZFS operations within one command. The following operations are possible:
- Creation a snapshot of one or multiple datasets
- Rotation (Deletion) of older snapshots of one or multiple datasets while keeping 8 daily, 5 weekly, 13 monthly and 6 yearly snapshots
- Replication of one or multiple datasets in a local or remote location through ZFS send
- Smart handling of initial & consecutive send operations
- Dry run mode for output testing without actual changes being made
- Optional logging

## Usage
Here are some examples of usage.

### Snapshotting of a local dataset
`zfsbud.sh --create pool/dataset1`
- `--create|-c` creates a snapshot for each dataset with the following name: `pool/dataset@auto_YYYYMMDDHHMMSS`
- Snapshot name prefix (default: `auto_`) can be overridden with `--snapshot-prefix|-p [cute_name_]`

### Rotating/deleting snapshots made with this script of two local datasets
`zfsbud.sh --remove-old pool/dataset1`
- `--remove-old|-r` removes snapshots created by this script only
- If you created snapshots with a customized snapshot prefix, make sure to pass this prefix like so `--snapshot prefix|-p [cute_name_]`
- Keeps 8 daily, 5 weekly, 13 monthly and 6 yearly snapshots

### Initial sending of a dataset to a remote
`zfsbud.sh --send remotepool_name --initial --rsh "ssh user@server -p22" pool/dataset1`
- `--initial|-i` will copy all snapshots over to the destination.
For it to work, the destination dataset needs to be unmounted and empty (no snapshots).
- This works with encrypted and unencrypted datasets.

### Consecutive sending of a dataset to a remote
`zfsbud.sh --send remote_pool_name --rsh "ssh user@server -p22" pool/dataset1`
- `--send|-s [remote_pool_name]` will figure out the last common snapshot between the source and destination and will send only the newer snapshots that are not present on the destination machine.
- This works with encrypted and unencrypted datasets.

### Create a snapshot of three datasets, rotate/remove old snapshots and send all changes to remote
`zfsbud.sh -c -r -s remote_pool_name --rsh "ssh user@server -p22" pool/dataset1 pool/dataset2 pool/dataset3`

### Logging
- To log, add `--log|-l` or `--log-path|-L [/path/to/file]`
- To add verbosity, add `--verbose|-v`.

### Dry run
To see the output of what would happen without making actual changes, add `--dry-run|-d`. This is highly recommended before any new usage of this script.

## Credit
Created and maintained by Pawel Ginalski (https://gbyte.dev).
