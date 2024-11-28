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
      log "===================== TAR WRAPPING CHECKSUM SCRIPT END ====================="
      exit 0
    fi
}

# Control check
control

# Path to folder
FPATH="${IS_DIGITAL}${DPX_WRAP}"
LOGS="${IS_DIGITAL}${DPX_SCRIPT_LOG}tar_wrapping_checksum.log"
FLIST="${IS_DIGITAL}${TAR_PRES}temp_file_list.txt"

# Refresh list / add items to list
rm "$FLIST"
touch "$FLIST"

if [ -z "$(ls -A ${FPATH})" ]
  then
    echo "Folder empty, for_tar_wrap, script exiting."
    exit 1
  else
    echo "=========== TAR WRAPPING CHECKSUM SCRIPT START =========== $date_FULL" >> "$LOGS"
    echo "Looking for files or folders in $FPATH" >> "$LOGS"
    echo "Writing any files/folders found to $FLIST:" >> "$LOGS"
fi

find "$FPATH" -maxdepth 1 -mindepth 1 -mmin +10 | while IFS= read -r items; do
  item=$(basename "$items")
  echo "$item"
  echo "${FPATH}${item}" >> "$FLIST"
done

cat "$FLIST" >> "$LOGS"

# Launching Python script using parallel
echo " Launching Python script to TAR wrap files/folders " >> "$LOGS"
grep "/mnt/" "$FLIST" | parallel --jobs 1 "${PY3_ENV} ${DPX_SCRIPTS}digiops_isilon/tar_wrapping_checksum.py {}"
echo " =========== TAR WRAPPING CHECKSUM SCRIPT END =========== $date_FULL" >> "$LOGS"
echo "" >> "$LOGS"
