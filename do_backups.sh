#!/bin/bash

# Encrypted backups script
#
# Purpose/summary
#
#   This script performs encrypted backups to rsync.net. The goal of these backups is to protect against sudden computer failure or theft. As
#   such, there is no history of past backups, just a single copy of the documents currently on the machine. During a backup some files
#   are duplicated to avoid data loss in case of a network outage or script error, but once a new backup is completed all old backup
#   files are deleted. There is no protection against slow disk failures (with read errors resulting in bad backups) or deleting a file
#   and not noticing before you run next the script.
#
# Operation
#
#   Documents on the local machine are broken into logical "archives", corresponding to non-overlapping directory trees. Each archive is
#   tar'd and encrypted with gpg before being backed up. Additionally, to avoid unnecessary network traffic, the sha512 sum of each tar
#   file is taken and checked against a checksum file on the remote machine. If it's a match then the old backup for that archive is retained
#   instead of uploading a new archive. If your disk speed is not substantially faster than your network speed you may want to disable this
#   feature and upload everything every time.
#
#   Ideally the list of local archives is a constant, to make it clear what is being backed up and what isn't, but I decided that I wanted all
#   of $HOME/Documents backed up with each subdirectory in a separate archive. As a compromise between these two goals I have a hard coded
#   list of these archives and check during script execution that this constant list matches the contents of my local disk.
#
# Invariants and assumptions
#
# - Backups are stored in `backups/${DATE}/${ARCHIVE_NAME}.tar.gpg`. The intetion is for backups to be run only once per day. Multiple runs of
#   the script in a single day will work, but if that's part of your use case you may want to consider a more granular naming scheme.
# - At script invocation if `backups/${DATE}` already exists it is moved to `backups/${DATE}.bak` to preserve the data until the new backup is
#   completed. If that directory also exists then `backups/${DATE}` is assumed to be the result of a more recent incomplete backup (i.e. not the
#   last successful backup) and is deleted instead. Other than this, no files are deleted until the successful completion of a backup, at which
#   point all backup files not part of the new backup are deleted.
# - It is assumed that the files to be backed up do not change during the execution of the backup script. If they do this this script offers
#   pretty much no guaranties on the data being backed up "correctly" -- the backup may not represent a state the local disk was ever in and
#   the stored hashes of archive tars might not actually be correct. (In practice these things are probably of little consequence, but don't
#   do it).
# - This script was designed to run on rsync.net, but it should work (with very minor adjustments? `quota`?) on any ssh-accessible system that
#   supports hardlinks that supports basic standard unix commands.
#
# Initial setup + usage
#
# - Create an account on rsync.net and ensure that the quota is large enough for two complete backups of your archives (i.e. the second backup
#   would work even if every archive changed and had to be uploaded again).
# - Create an entry in .ssh/config defining the rsyncnet host with the appropriate username, address, and key (see the `setup` function).
# - Upload your public key to rsync.net (see the `setup` function below for sample commands).
# - Ensure that you have a system for recalling your rsync.net user/host/key or password and your gpg key that does not require your computer.
#   For bonus points also ensure you have access to the sample commands for decrypting your backups.
# - It is assumed that the gpg password is written to ${GPG_PASS_FILE}='/tmp/backup_pass'. Write that file before running backups. Ensure
#   that the file is only redable by the desired set of users.
# - Run the script to generate your first backup
# - On another machine (or pretend _really_ hard that your machine is another machine -- don't depend on your .ssh/config or keys) follow your
#   procedure for downloading a backed up archive and decrypting it.

set -e

GPG_PASS_FILE='/tmp/backup_pass'

if [ ! -f "${GPG_PASS_FILE}" ]; then
  echo "ERROR: ${GPG_PASS_FILE} doesn't exist"
  exit 1
fi

SSH_CMD="ssh rsyncnet"

DATE=$(date --iso)
BACKUPS_DIR="backups"
DEST_DIR="${BACKUPS_DIR}/${DATE}"
DEST_DIR_BAK="${DEST_DIR}.bak"

function tar_dir {
  BDIR="${1}"
  DIRNAME=$(dirname "${BDIR}")
  BASENAME=$(basename "${BDIR}")
  cd "${DIRNAME}"
  ionice -c idle tar -cf /dev/stdout "${BASENAME}" 2>/dev/null
}

function backup_dir {
  BDIR="${1}"
  BASENAME=$(basename "${BDIR}")
  NAME="${BASENAME}.tar"

  # Compute hash
  HASH=$(tar_dir "${BDIR}" | sha512sum | awk '{print $1}')
  HASH_FILE="${NAME}.${HASH}"

  # Search for hash file on backup server
  REMOTE_HASH_FILE=$($SSH_CMD find "${BACKUPS_DIR}" -name "${HASH_FILE}" | head -n1)
  if [ -n "${REMOTE_HASH_FILE}" ] ; then
    REMOTE_DIR=$(dirname "${REMOTE_HASH_FILE}")
    echo "Found remote hash file for ${NAME}.gpg in ${REMOTE_DIR}"
    $SSH_CMD ln "${REMOTE_DIR}/${NAME}.gpg" "${DEST_DIR}/${NAME}.gpg"
    echo
  else
    SIZE=$(du --apparent-size -sh "${BDIR}")
    echo "Backing up ~${SIZE} bytes for to ${NAME}.gpg"
    tar_dir "${BDIR}" | backup_stdin "${NAME}"
  fi

  # Upload hash file
  $SSH_CMD touch "${DEST_DIR}/${HASH_FILE}"
}

function backup_stdin {
  DEST="${DEST_DIR}/${1}.gpg"
  echo "Backing up data to ${DEST}..."
  gpg --batch "--passphrase-file=${GPG_PASS_FILE}" --compress-algo=none --symmetric | $SSH_CMD dd "of=${DEST}" bs=1M status=progress
  # Decrypt: gpg -d --batch "--passphrase-file=${GPG_PASS_FILE}"
  echo "Backed up data to ${DEST}."
  echo
}

echo "Running prechecks"
EXPECTED_DOC_DIRS=(
  "/home/david/Documents/Anki"
  "/home/david/Documents/archive"
  "/home/david/Documents/blair"
  "/home/david/Documents/books"
  "/home/david/Documents/code"
  "/home/david/Documents/coursera"
  "/home/david/Documents/doorcomics"
  "/home/david/Documents/jobs"
  "/home/david/Documents/journal"
  "/home/david/Documents/misc"
  "/home/david/Documents/mit"
  "/home/david/Documents/MuseScore2"
  "/home/david/Documents/music"
  "/home/david/Documents/notes"
  "/home/david/Documents/passwords"
  "/home/david/Documents/photos"
  "/home/david/Documents/projects"
  "/home/david/Documents/renting_information"
  "/home/david/Documents/sheet_music"
  "/home/david/Documents/tax_stuff"
)

DOC_DIRS=$(find '/home/david/Documents/' -mindepth 1 -maxdepth 1 -type d -not -name 'videos' | sort | tr "\n" " " | sed 's/ *$//')
if [ "${DOC_DIRS}" != "${EXPECTED_DOC_DIRS[*]}" ]; then
  echo "Mismatched doc dirs:"
  echo "Expected: ${EXPECTED_DOC_DIRS[*]}"
  echo "Actual  : ${DOC_DIRS}"
  exit 1
fi

# Create destination directory for this backup, archiving an old directory of the same name if relevant
echo "Setup backup environment"
DEST_EXISTS=$($SSH_CMD ls -d "${DEST_DIR}" 2>/dev/null || :)
DEST_BAK_EXISTS=$($SSH_CMD ls -d "${DEST_DIR_BAK}" 2>/dev/null || :)
if [ -n "$DEST_EXISTS" ]; then
  if [ -z "$DEST_BAK_EXISTS" ]; then
    echo "Backing up backup directory of the same name"
    $SSH_CMD mv "$DEST_DIR" "$DEST_DIR_BAK"
  else
    echo "Backup-backup already exists; cleaning the backup directory"
    $SSH_CMD rm -rf "${DEST_DIR}"
  fi
fi
${SSH_CMD} mkdir -p "${DEST_DIR}"
echo

QUOTA_BEGIN=$($SSH_CMD quota)

# Back up all of Documents except for videos
for DOC_DIR in ${DOC_DIRS}
do
  backup_dir "${DOC_DIR}"
done

# Back up specific paths
backup_dir "/home/david/Documents/videos/special"
backup_dir "/home/david/Desktop"
backup_dir "/etc"

# Back up command outputs
tree /home/david/Documents/videos/findable | backup_stdin "cmd_videos_findable"
tree /home/david/Documents/videos/tmp      | backup_stdin "cmd_videos_tmp"

# Delete other/older backups
echo "Deleting old backups"
QUOTA_MAX=$($SSH_CMD quota)
$SSH_CMD find backups -mindepth 1 -maxdepth 1 -not -name "${DATE}" -exec rm -rf "{}" "\;"

QUOTA_END=$($SSH_CMD quota)

echo "Quotas begin/max/end:"
echo "${QUOTA_BEGIN}"
echo
echo "${QUOTA_MAX}"
echo
echo "${QUOTA_END}"

#################################
# Other utilities/sample commands
function setup {
  # Entry in .ssh/config:
  # Host rsyncnet
  #     Hostname ********.rsync.net
  #     User your_username
  #     IdentityFile ~/.ssh/id_ed25519

  cat ~/.ssh/id_ed25519.pub | ${SSH_CMD} dd of=.ssh/authorized_keys
}

function inspect {
  ${SSH_CMD} find backups
}

function download {
  NAME="${1}"
  REMOTE_PATH=$(${SSH_CMD} find backups -name "${NAME}")
  ${SSH_CMD} dd if=${REMOTE_PATH} bs=1M | dd of="/tmp/${NAME}"
}
