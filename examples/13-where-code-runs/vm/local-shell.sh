#!/usr/bin/env bash
# local-shell.sh - a stand-in for scripts/lab/lab-ssh.sh INSIDE the guest.
#
# lib.sh's `guest` and `container_run` reach the lab guest with `$LAB_SSH TARGET COMMAND...` (ssh over
# vsock from the host). vm/guest-run.sh already runs in the guest, so it points LAB_SSH here: the target
# is ignored and the command runs in a local bash from the guest user's home, which is where ssh would
# start it. Nothing leaves the guest.
shift # the target name
cd "$HOME" || exit 1
exec bash -c "$*"
