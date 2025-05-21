#!/bin/bash -x

# ============================================
# Launch script for Film Ops tar wrap script =
# ============================================

date_FULL=$(date +'%Y-%m-%d - %T')

# Function to check for control json activity
function control {
    boole=$(cat "${LOG_PATH}downtime_control.json" | grep "rawcooked" | awk -F': ' '{print $2}')
    if [ "$boole" = false, ] ; then
      log "Control json requests script exit immediately"
      log "===================== DPX assessment workflow ENDED ====================="
      exit 0
    fi
}

# Control check
control

# Path to folder
PTH="$1"
FPATH="${PTH}${DPX_WRAP}"
LOGS="${LOG_PATH}tar_wrapping_checksum.log"
FLIST="${PTH}${TAR_PRES}temp_file_list.txt"

if [ -z "$(ls -A ${FPATH})" ]
  then
    echo "Folder empty, for_tar_wrap, script exiting."
    exit 1
  else
    echo "=========== TAR WRAPPING CHECKSUM $1 START =========== $date_FULL" >> "$LOGS"
    echo "Looking for files or folders in $FPATH" >> "$LOGS"
    echo "Writing any files/folders found to $FLIST:" >> "$LOGS"
fi

# Refresh list / add items to list
echo "" > "$FLIST"

find "$FPATH" -maxdepth 1 -mindepth 1 -mmin +10 | while IFS= read -r items; do
  item=$(basename "$items")
  echo "$item"
  echo "${FPATH}${item}" >> "$FLIST"
done

cat "$FLIST" >> "$LOGS"

# Launching Python script using parallel
echo " Launching Python script to TAR wrap files/folders " >> "$LOGS"
grep "/mnt/" "$FLIST" | parallel --jobs 1 "${PYENV311} ${DPX_SCRIPTS}tar_wrapping_checksum.py {}"
echo " =========== TAR WRAPPING CHECKSUM SCRIPT END =========== $date_FULL" >> "$LOGS"
echo "" >> "$LOGS"
