# zfsbud
ZFS snapshotting, replicating & backup rotating convenience bash script.

## Introduction
This is a convenience script that helps to manage multiple ZFS operations within one command. The aim here is to pack flexible functionality into a standalone script which will remain one (as opposed to becoming packaged software that depends on python/perl/what-have-you).

The script tries to be smart about things like automatically resuming a stream choosing the right snapshots on both sides for incremental send. It is very verbose and informs about potential problems and misconfiguration in advance.

The following operations are possible:
- Creation of a snapshot of one or multiple datasets
- Rotation (selective deletion) of older snapshots of one or multiple datasets while keeping 8 daily, 5 weekly, 13 monthly and 6 yearly snapshots (snapshot retention can be configured in the configuration file)
- Resumable sending/replication of one or multiple datasets to a local or remote location through ZFS send
- Smart/automatic handling of initial & consecutive send operations
- Optional recursive dataset creation and sending
- Resuming of the last operation in case of an interruption
- Dry run mode for output testing without actual changes being made
- Optional logging

## Usage
Here are some usage examples.

### Snapshotting of a local dataset
`zfsbud.sh --create-snapshot some_label dataset/path1`
- `--create-snapshot|-c [label]` creates a snapshot for each dataset with the following name: `dataset/path@zfsbud_YYYYMMDDHHMMSS_some_label`
- The label is optional.
- Snapshot name prefix (default: `zfsbud_`) can be overridden during runtime with `--snapshot-prefix|-p <cute_prefix_>`, or permanently in the configuration file.
- To snapshot recursively, add `--recursive|-R`.

### Rotating/deleting of a dataset's snapshots made with this script
`zfsbud.sh --remove-old dataset/path1`
- `--remove-old|-r` removes snapshots created by this script only
- To delete recursively, add `--recursive|-R`.
- If you created snapshots with a prefix that is not defined in the configuration file, make sure to pass that prefix like so `--snapshot prefix|-p <cute_prefix_>`
- In addition to the newest snapshot and (in case the `--send|-s` flag is passed) the most recent common snapshot, snapshots are kept according to the snapshot retention policy defined in the configuration file.

### Initial sending of a dataset to a remote
`zfsbud.sh --send destination_parent_dataset/path --initial --rsh "ssh user@server -p22" dataset/path1`
- `--initial|-i` will copy all snapshots over to the destination.
- To send recursively, add `--recursive|-R`.
- The destination dataset must be non-existent.

### Consecutive sending of a dataset to a remote
`zfsbud.sh --send destination_parent_dataset/path --rsh "ssh user@server -p22" dataset/path1`
- `--send|-s <destination_parent_dataset/path>` will figure out the last common snapshot between the source and destination and will send only the newer snapshots that are not present on the destination machine.
- This will destroy destination snapshots that have been created between the last common snapshot and the newest source snapshot, including the ones not made with zfsbud.
- It will replicate all snapshots from source to destination between the last common snapshot and the newest source snapshot, including the ones not made with zfsbud.
- This works with encrypted and unencrypted datasets.
- To send recursively, add `--recursive|-R`.

### Creating resumable streams & resuming
- The script implicitly creates resumable streams and resumes a stream when it finds a matching token on the receiving side.
- This works for initial and consecutive sending.

### Disabling resume functionality
`zfsbud.sh --send destination_parent_dataset/path --no-resume --rsh "ssh user@server -p22" dataset/path1`
- If a non-resumable stream is desired, or resuming an incomplete stream is undesired, `--no-resume|-n` must be used.

### Create a snapshot of three datasets labeled "after_update", rotate/remove old snapshots and send all changes to remote
`zfsbud.sh -c after_update -r -s destination_parent_dataset/path -e "ssh user@server -p22" dataset/path1 dataset/path2 dataset/path3`

### Logging
- To log, add `--log|-l` or `--log-path|-L </path/to/file>`
- To add verbosity, add `--verbose|-v`.

### Dry run
To see the output of what would happen without making actual changes, add `--dry-run|-d`. This is highly recommended before any new utilization of this script.

### Help
Use `--help|-h` to show help.
```
Usage: zfsbud [OPTION]... SOURCE/DATASET/PATH [SOURCE/DATASET/PATH2...]

 -s, --send <destination_parent_dataset/path> send source dataset incrementally to specified destination
 -i, --initial                                initially clone source dataset to destination (requires --send)
 -n, --no-resume                              do not create resumable streams and do not resume streams (requires --send)
 -e, --rsh <'ssh user@server -p22'>           send to remote destination by providing ssh connection string (requires --send)
 -c, --create-snapshot [label]                create a timestamped snapshot on source with an optional label
 -R, --recursive                              send or snapshot dataset recursively along with child datasets (requires --send or --create-snapshot)
 -r, --remove-old                             remove old snapshots according to the policy defined in the configuration file
 -d, --dry-run                                show output without making actual changes
 -p, --snapshot-prefix <prefix>               use a snapshot prefix other than the one defined in the configuration file
 -v, --verbose                                increase verbosity
 -l, --log                                    log to user's home directory
 -L, --log-path </path/to/file>               provide path to log file (implies --log)
 -h, --help                                   show this help
```

## ToDo
- Resume stream dynamically in recursive sends on a per dataset basis. At the moment, during a recursive send operation, if sending of a child dataset was interrupted, that dataset has to be sent again with zfsbud. The script will then resume the sending of that dataset autonomously. A better way of handling that would be just repeating the previous operation and letting zfsbud check if there is a resume token for each recursively sent dataset.

## Caution
This script does things. Don't use when tired or drugged.

## Resources
For more resources and examples, see https://gbyte.dev/project/zfsbud

## Credit
Created and maintained by Pawel Ginalski (https://gbyte.dev).
