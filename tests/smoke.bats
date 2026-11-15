load test_helper

setup() {
  setup_yazi rclone
  STUB="$BATS_TEST_TMPDIR/stub"
  MNT="$BATS_TEST_TMPDIR/mnt"
  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$STUB/bin" "$MNT"
  export STUB
  : >"$STUB/mounttable"

  # an `rclone` that is a script: it says which remotes there are, and when it is asked to mount it
  # writes the mount in a table, which `mount` prints, and a file in the mount point
  cat >"$STUB/bin/rclone" <<'SH'
#!/bin/sh
case "$1" in
  listremotes) cat "$STUB/remotes" ;;
  mount | nfsmount)
    echo "$*" >>"$STUB/calls.log"
    echo "$2 on $3 type fuse.rclone (rw,nosuid,nodev)" >>"$STUB/mounttable"
    echo hello >"$3/hello.txt"
    ;;
esac
SH
  cat >"$STUB/bin/mount" <<'SH'
#!/bin/sh
cat "$STUB/mounttable"
SH
  cat >"$STUB/bin/fusermount" <<'SH'
#!/bin/sh
echo "fusermount $*" >>"$STUB/calls.log"
grep -v " on $2 type " "$STUB/mounttable" >"$STUB/mounttable.new"
mv "$STUB/mounttable.new" "$STUB/mounttable"
SH
  chmod +x "$STUB/bin/"*
  printf 'gdrive:\ns3:\n' >"$STUB/remotes"
  export PATH="$STUB/bin:$PATH"

  echo "require(\"rclone\"):setup { mount_dir = \"$MNT\", cache_dir = \"$CACHE\" }" >"$YAZI_CONFIG_HOME/init.lua"
  cat >"$YAZI_CONFIG_HOME/keymap.toml" <<'KEYS'
[mgr]
prepend_keymap = [
  { on = ["R", "m"], run = "plugin rclone mount", desc = "Mount" },
  { on = ["R", "u"], run = "plugin rclone unmount", desc = "Unmount" },
  { on = ["R", "j"], run = "plugin rclone mounts", desc = "Mounts" },
  { on = ["R", "x"], run = "plugin rclone oops", desc = "A wrong argument" },
]
KEYS
  echo hello >"$WORK/aaa.txt"
}

teardown() { stop_yazi; }

calls() { cat "$STUB/calls.log" 2>/dev/null || true; }

# the keys of a mount: the menu of remotes, the number of the remote, the path, and Enter
mount_remote() {
  send_keys R
  send_keys m
  send_keys "$1"
  [ -z "${2:-}" ] || send_keys "$2"
  send_keys Enter
  sleep 2
}

@test "the menu lists the remotes of rclone" {
  start_yazi
  send_keys R
  send_keys m
  assert_healthy
  assert_screen "gdrive:"
  assert_screen "s3:"
}

@test "a remote with a path is mounted under the mount directory and Yazi goes there" {
  start_yazi
  mount_remote 2 bucket
  assert_healthy
  calls | grep -q "^mount s3:bucket $MNT/s3/bucket --daemon --cache-dir $CACHE/s3/bucket --vfs-cache-mode writes"
  assert_screen "hello.txt"
}

@test "an empty path mounts the root of the remote" {
  start_yazi
  mount_remote 2
  assert_healthy
  calls | grep -q "^mount s3: $MNT/s3 --daemon"
}

@test "nothing is mounted when the path is cancelled" {
  start_yazi
  send_keys R
  send_keys m
  send_keys 2
  send_keys Escape
  assert_healthy
  [ -z "$(calls)" ]
}

@test "a remote that is mounted already is not mounted again" {
  mkdir -p "$MNT/s3/bucket"
  echo hello >"$MNT/s3/bucket/hello.txt"
  echo "s3:bucket on $MNT/s3/bucket type fuse.rclone (rw)" >"$STUB/mounttable"
  start_yazi
  mount_remote 2 bucket
  assert_healthy
  [ -z "$(calls)" ]
  assert_screen "hello.txt"
}

@test "macOS mounts through NFS" {
  printf '#!/bin/sh\necho Darwin\n' >"$STUB/bin/uname"
  chmod +x "$STUB/bin/uname"
  start_yazi
  mount_remote 2
  assert_healthy
  calls | grep -q "^nfsmount s3: $MNT/s3 --daemon"
}

@test "unmount from inside a mount leaves it and unmounts it" {
  start_yazi
  mount_remote 2 bucket
  send_keys R
  send_keys u
  sleep 2
  assert_healthy
  calls | grep -q "fusermount -u $MNT/s3/bucket"
  ! grep -q "$MNT/s3/bucket" "$STUB/mounttable"
}

@test "the menu of the mounts goes to the one that is chosen" {
  mkdir -p "$MNT/s3/bucket" "$MNT/gdrive/docs"
  echo from-s3 >"$MNT/s3/bucket/s3-file.txt"
  echo from-gdrive >"$MNT/gdrive/docs/gdrive-file.txt"
  { echo "s3:bucket on $MNT/s3/bucket type fuse.rclone (rw)"; echo "gdrive:docs on $MNT/gdrive/docs type fuse.rclone (rw)"; } >"$STUB/mounttable"
  start_yazi
  send_keys R
  send_keys j
  assert_screen "s3/bucket"
  assert_screen "gdrive/docs"
  send_keys 2
  sleep 2
  assert_healthy
  assert_screen "s3-file.txt"
}

@test "no remote is a message that says how to set one up" {
  : >"$STUB/remotes"
  start_yazi
  send_keys R
  send_keys m
  assert_screen "rclone config"
}

@test "a wrong argument is an error that says what to use" {
  start_yazi
  send_keys R
  send_keys x
  assert_screen "plugin rclone mount"
}
