#!/bin/bash -x

# ====================================================================
# === Clean up and inspect logs for problem DPX sequence encodings ===
# ====================================================================

# Global variables extracted from environmental vars
ERRORS="${QNAP_FILMOPS2}${CURRENT_ERRORS}"
DPX_PATH="${QNAP_FILMOPS2}${RAWCOOKED_PATH}"
DPX_DEST="${QNAP_FILMOPS2}${DPX_COMPLETE}"
MKV_DESTINATION="${QNAP_FILMOPS2}${MKV_ENCODED}"
CHECK_FOLDER="${QNAP_FILMOPS2}${MKV_CHECK}"
MKV_POLICY="${POLICY_RAWCOOK}"
SCRIPT_LOG="${QNAP_FILMOPS2}${DPX_SCRIPT_LOG}"

function control {
    boole=$(cat "${CONTROL_JSON}" | grep "power_off_all" | awk -F': ' '{print $2}')
    if [ "$boole" = false, ] ; then
      echo "Control json requests script exit immediately" >> "${LOG}"
      echo 'Control json requests script exit immediately'
      exit 0
    fi
}

# Control check inserted into code
control

# Function to write output to log, call 'log' + 'statement' that populates $1.
function log {
    timestamp=$(date "+%Y-%m-%d - %H.%M.%S")
    echo "$1 - $timestamp"
} >> "${SCRIPT_LOG}dpx_post_rawcook.log"

# Global date variable
DATE_FULL=$(date +'%Y-%m-%d  - %T')

# Check mkv_cooked/ folder populated before starting log writes
if [ -z "$(ls -A ${MKV_DESTINATION}mkv_cooked/)" ]
  then
    echo "MKV folder empty, script exiting."
    exit 1
  else
    log "===================== Post-RAWcook workflows STARTED ====================="
    log "Files present in mkv_cooked folder, checking if ready for processing..."
fi

# Script temporary file recreate (delete at end of script
touch "${MKV_DESTINATION}successful_mkv_list.txt"
touch "${MKV_DESTINATION}matroska_deletion.txt"
touch "${MKV_DESTINATION}matroska_deletion_list.txt"
touch "${MKV_DESTINATION}stale_encodings.txt"
touch "${MKV_DESTINATION}error_list.txt"
touch "${MKV_DESTINATION}temp_fail_mkv_list.txt"
# Deleted in dpx_rawcook.sh
touch "${MKV_DESTINATION}reversibility_list.txt"

# =======================================================================================
# Matroska size check remove files to Killed folder, and folders moved to check_size/ ===
# =======================================================================================

find "${MKV_DESTINATION}mkv_cooked/" -name "*.mkv" -mmin +80 | while IFS= read -r fname; do
    filename=$(basename "$fname")
    fname_log=$(echo "$filename" | rev | cut -c 5- | rev)
    object=$(echo "$filename" | rev | cut -c 12- | rev)
    size=$(du -m "$fname" | cut -f1 )
    if [ "${size}" -gt 1048560 ]
        then
            echo "$filename" >> "${MKV_DESTINATION}temp_fail_mkv_list.txt"
            log "${filename} maybe larger than 1TB: ${size}mb. Moving to killed/ folder"
            log "Moving failed ${filename}.log to ${MKV_DESTINATION}logs/"
            echo "post_rawcooked $(date "+%Y-%m-%d - %H.%M.%S"): Matroska ${filename} is over 1TB." >> "${ERRORS}${fname_log}_errors.log"
            echo "    Matroska moved to Killed folder. All multipart DPX part wholes may need reviewing." >> "${ERRORS}${fname_log}_errors.log"
            echo "    Please contact the Knowledge and Collections Developer about this repeated encoding failure." >> "${ERRORS}${fname_log}_errors.log"
            echo "${object}" >> "${ERRORS}part_whole_search.log"
            log "**** WARNING! ${filename} TOO LARGE TO INGEST TO DPI ****"
            log "**** REMOVE ALL PART OF WHOLE FILES FOR ${filename} SPLITTING ****"
        else
            log "File ${filename} is under 1TB in size. Looking for completed log check."
    fi
done

# Move files outside of while loop
grep ^N_ "${MKV_DESTINATION}temp_fail_mkv_list.txt" | parallel --jobs 3 mv "${MKV_DESTINATION}mkv_cooked/{}" "${MKV_DESTINATION}killed/Oversize_{}.mkv"
grep ^N_ "${MKV_DESTINATION}temp_fail_mkv_list.txt" | parallel --jobs 3 mv "${MKV_DESTINATION}mkv_cooked/{}.txt" "${MKV_DESTINATION}logs/failed_oversize_{}.txt"

# ====================================================================================================
# Log check/mediaconch check passes move to MKV Check folder and logs folders, and DPX folder move ===
# ====================================================================================================

find "${MKV_DESTINATION}mkv_cooked/" -name "*.mkv.txt" -mmin +30 | while IFS= read -r fname; do
  success_check=$(grep 'Reversibility was checked, no issue detected.' "$fname")
  mkv_filename=$(basename "$fname" | rev | cut -c 5- | rev )
  dpx_success_path=$(echo "$fname" | rev | cut -c 9- | rev )
  if [ -z "$success_check" ];
    then
      log "SKIPPING FILE: $mkv_filename has not completed, or has errors detected"
    else
      log "COMPLETED: RAWcooked MKV $mkv_filename has completed successfully and will be checked against MediaConch policy"
      echo "$dpx_success_path" >> "${MKV_DESTINATION}rawcooked_success.log"
      echo "$mkv_filename" >> "${MKV_DESTINATION}successful_mkv_list.txt"
  fi
done

# Run Matroska policy validations
touch "${MKV_DESTINATION}temp_success_mkv_list.txt"
echo '' > "${MKV_DESTINATION}temp_fail_mkv_list.txt"

while read mkvs; do
  log "Checking $mkvs against Matroska MediaConch policy"
  check=$(mediaconch --force -p "$MKV_POLICY" "${MKV_DESTINATION}mkv_cooked/${mkvs}" | grep "pass! ${MKV_DESTINATION}mkv_cooked/${mkvs}")
  fname=$(echo "$mkvs" | rev | cut -c 5- | rev)
  if [ -z "$check" ];
    then
      log "FAIL: RAWcooked MKV $mkvs has failed the mediaconch policy"
      log "Moving $mkvs to killed directory, and amending log fail_$mkvs.txt"
      log "$check"
      echo "post_rawcooked $(date "+%Y-%m-%d - %H.%M.%S"): Matroska $mkvs failed the FFV1 MKV Mediaconch policy." >> "${ERRORS}${fname}_errors.log"
      echo "    Matroska moved to Killed folder, DPX sequence will retry RAWcooked encoding." >> "${ERRORS}${fname}_errors.log"
      echo "    Please contact the Knowledge and Collections Developer about this Mediaconch policy failure." >> "${ERRORS}${fname}_errors.log"
      echo "$mkvs" >> "${MKV_DESTINATION}temp_fail_mkv_list.txt"
    else
      log "PASS: RAWcooked MKV file $mkvs has passed the Mediaconch policy. Whoopee"
      echo "$fname" >> "${MKV_DESTINATION}temp_success_mkv_list.txt"
  fi
done < "${MKV_DESTINATION}successful_mkv_list.txt"

# Move failed MKV files to killed folder and logs prepended fail_
grep ^N_ "${MKV_DESTINATION}temp_fail_mkv_list.txt" | parallel --jobs 3 mv "${MKV_DESTINATION}mkv_cooked/{}" "${MKV_DESTINATION}killed/{}"
grep ^N_ "${MKV_DESTINATION}temp_fail_mkv_list.txt" | parallel --jobs 3 mv "${MKV_DESTINATION}mkv_cooked/{}.txt" "${MKV_DESTINATION}logs/fail_{}.txt"

# Move successfully encoded MKV files to check folder and logs/ folder and DPX
grep ^N_ "${MKV_DESTINATION}temp_success_mkv_list.txt" | parallel --jobs 3 mv "${MKV_DESTINATION}mkv_cooked/{}.mkv" "${MKV_DESTINATION}check/{}.mkv"
grep ^N_ "${MKV_DESTINATION}temp_success_mkv_list.txt" | parallel --jobs 3 mv "${MKV_DESTINATION}mkv_cooked/{}.mkv.txt" "${MKV_DESTINATION}logs/{}.mkv.txt"
grep ^N_ "${MKV_DESTINATION}temp_success_mkv_list.txt" | parallel --jobs 3 mv "${DPX_PATH}dpx_to_cook/{}" "${DPX_DEST}{}"

rm "${MKV_DESTINATION}temp_success_mkv_list.txt"
rm "${MKV_DESTINATION}temp_fail_mkv_list.txt"

# Add list of moved items to post_rawcooked.log
if [ -s "${MKV_DESTINATION}successful_mkv_list.txt" ];
  then
    log "Successful Matroska files moved to check folder, DPX sequences for each moved to dpx_completed:"
    cat "${MKV_DESTINATION}successful_mkv_list.txt" >> "${SCRIPT_LOG}dpx_post_rawcook.log"
  else
    echo "File is empty, skipping"
fi

# ==========================================================================
# Error: the reversibility file is becoming big. --output-version 2 pass ===
# ==========================================================================

find "${MKV_DESTINATION}mkv_cooked/" -name "*.mkv.txt" -mmin +30 | while IFS= read -r large_logs; do
  error_check1=$(grep 'Error: undecodable file is becoming too big.\|Error: the reversibility file is becoming big.' "$large_logs")
  mkv_fname1=$(basename "$large_logs" | rev | cut -c 5- | rev )
  dpx_folder1=$(basename "$large_logs" | rev | cut -c 9- | rev )
  if [ -z "$error_check1" ];
    then
      log "MKV ${mkv_fname1} log has no large reversibility file warning. Skipping."
    else
      retry_check1=$(grep "$mkv_fname1" "${MKV_DESTINATION}reversibility_list.txt")
      log "MKV ${mkv_fname1} has error detected. Checking if already had --output-version 2 pass"
      if [ -z "$retry_check1" ];
        then
          log "NEW ENCODING ERROR: ${mkv_fname1} adding to reversibility_list"
          echo "${DPX_PATH}dpx_to_cook/${dpx_folder1}" >> "${MKV_DESTINATION}reversibility_list.txt"
          mv "${large_logs}" "${MKV_DESTINATION}logs/retry_${mkv_fname1}.txt"
        else
          log "REPEAT ENCODING ERROR: ${mkv_fname1} encountered repeated reversibility data error"
          echo "post_rawcooked $(date "+%Y-%m-%d - %H.%M.%S"): ${mkv_fname1} Repeated reversibility data error for sequence:" >> "${ERRORS}${dpx_folder1}_errors.log"
          echo "    ${DPX_PATH}dpx_to_cook/${dpx_folder1}" >> "${ERRORS}${dpx_folder1}_errors.log"
          echo "    The FFV1 Matroska will be deleted." >> "${ERRORS}${dpx_folder1}_errors.log"
          echo "    Please contact the Knowledge and Collections Developer about this repeated reversibility failure." >> "${ERRORS}${dpx_folder1}_errors.log"
          echo "${mkv_fname1}" >> "${MKV_DESTINATION}matroska_deletion.txt"
          mv "${large_logs}" "${MKV_DESTINATION}logs/fail_${mkv_fname1}.txt"
      fi
  fi
done

# Add list of reversibility data error to dpx_post_rawcooked.log
if [ -s "${MKV_DESTINATION}matroska_deletion.txt" ];
  then
    log "MKV files that will be deleted due to reversibility data error in logs (if present):"
    cat "${MKV_DESTINATION}matroska_deletion.txt" >> "${SCRIPT_LOG}dpx_post_rawcook.log"
    # Delete broken Matroska files if they exist (unlikely as error exits before encoding)
    grep ^N_ "${MKV_DESTINATION}matroska_deletion.txt" | parallel --jobs 10 rm "${MKV_DESTINATION}mkv_cooked/{}"
  else
    echo "No MKV files for deletion. Skipping."
fi

# Add reversibility list to logs for reference
if [ -s "${MKV_DESTINATION}reversibility_list.txt" ];
  then
    log "DPX sequences that will be re-encoded using --output-version 2:"
    cat "${MKV_DESTINATION}reversibility_list.txt" >> "${SCRIPT_LOG}dpx_post_rawcook.log"
  else
    echo "No DPX sequences for re-encoding using --output-version 2. Skipping."
fi

# ===================================================================================
# General Error/Warning message failure checks - retry or raise in current errors ===
# ===================================================================================

find "${MKV_DESTINATION}mkv_cooked/" -name "*.mkv.txt" -mmin +30 | while IFS= read -r fail_logs; do
  error_check=$(grep 'Reversibility was checked, issues detected\|Error:\|Conversion failed!\|Please contact info@mediaarea.net if you want support of such content.\|DPX marker not found\|Error while decoding stream' "$fail_logs")
  mkv_fname=$(basename "$fail_logs" | rev | cut -c 5- | rev )
  dpx_folder=$(basename "$fail_logs" | rev | cut -c 9- | rev )
  if [ -z "$error_check" ];
    then
      log "MKV ${mkv_fname} log has no error messages. Likely an interrupted or incomplete encoding"
    else
      log "UNKNOWN ENCODING ERROR: ${mkv_fname} encountered error"
      echo "${DPX_PATH}dpx_to_cook/${dpx_folder}" >> "${MKV_DESTINATION}error_list.txt"
      echo "post_rawcooked $(date "+%Y-%m-%d - %H.%M.%S"): ${mkv_fname} Repeat encoding error raised for sequence:" >> "${ERRORS}${dpx_folder}_errors.log"
      echo "    ${DPX_PATH}dpx_to_cook/${dpx_folder}" >> "${ERRORS}${dpx_folder}_errors.log"
      echo "    The Matroska file will be deleted." >> "${ERRORS}${dpx_folder}_errors.log"
      echo "    Please contact the Knowledge and Collections Developer about this repeated encoding failure." >> "${ERRORS}${dpx_folder}_errors.log"
      echo "${mkv_fname}" >> "${MKV_DESTINATION}matroska_deletion_list.txt"
      mv "${fail_logs}" "${MKV_DESTINATION}logs/fail_${mkv_fname}.txt"
  fi
done

# Add list of encoding error/warning logs to dpx_post_rawcooked.log
if [ -s "${MKV_DESTINATION}matroska_deletion_list.txt" ];
  then
    log "MKV files that will be deleted due to repeated error in logs:"
    cat "${MKV_DESTINATION}matroska_deletion_list.txt" >> "${SCRIPT_LOG}dpx_post_rawcook.log"
    # Delete broken Matroska files
    grep ^N_ "${MKV_DESTINATION}matroska_deletion_list.txt" | parallel --jobs 10 rm "${MKV_DESTINATION}mkv_cooked/{}"
  else
    echo "No MKV files for deletion at this time. Skipping."
fi

# ===============================================================
# FOR ==== INCOMPLETE ==== - i.e. killed processes ==============
# ===============================================================

# This block manages the remaining INCOMPLETE cooks that have been killed or stalled mid-encoding
find "${MKV_DESTINATION}mkv_cooked/" -name "*.mkv.txt" -mmin +36000 -size +10k | while IFS= read -r stale_logs; do
  stale_fname=$(echo "$stale_logs" | rev | cut -c 5- | rev )
  stale_basename=$(basename "$stale_logs")
  fname_log=$(echo "$stale_basename" | rev | cut -c 9- | rev )
  log "Stalled/killed encoding: ${stale_basename}. Adding to stalled list and deleting log file and Matroska"
  echo "${stale_fname}" >> "${MKV_DESTINATION}stale_encodings.txt"
  echo "post_rawcooked $(date "+%Y-%m-%d - %H.%M.%S"): Matroska ${stale_fname} encoding stalled mid-process." >> "${ERRORS}${fname_log}_errors.log"
  echo "    Matroska and failed log deleted. DPX sequence will retry RAWcooked encoding." >> "${ERRORS}${fname_log}_errors.log"
  echo "    Please contact the Knowledge and Collections Developer if this item repeatedly stalls." >> "${ERRORS}${fname_log}_errors.log"
done

# Add list of stalled logs to post_rawcooked.log
if [ -s "${MKV_DESTINATION}stale_encodings.txt" ];
  then
    log "Stalled files that will be deleted:"
    cat "${MKV_DESTINATION}stale_encodings.txt" >> "${SCRIPT_LOG}dpx_post_rawcook.log"
    # Delete broken log files
    grep '/mnt/' "${MKV_DESTINATION}stale_encodings.txt" | parallel --jobs 10 'rm {}.txt'
    grep '/mnt/' "${MKV_DESTINATION}stale_encodings.txt" | parallel --jobs 10 'rm {}.rawcooked_reversibility_data'
  else
    echo "No stale encodings to process at this time. Skipping."
fi

# Check for and delete broken Matroska files if they exist
grep '/mnt/' "${MKV_DESTINATION}stale_encodings.txt" | while IFS= read -r stale_mkv; do
  if [ ! -f "${stale_mkv}" ]
    then
      true
    else
      rm "${stale_mkv}"
  fi
done

# Write an END note to the logfile
log "===================== Post-rawcook workflows ENDED ====================="

# Update the count of successful cooks at top of the success log
# First create new temp_success_log with timestamp
echo "===================== Updated ===================== $DATE_FULL" > "${MKV_DESTINATION}temp_rawcooked_success.log"

# Count lines in success_log and create count variable, output that count to new success log, then output all lines with /mnt* to the new log
cat "${MKV_DESTINATION}rawcooked_success.log" | grep '/mnt/' >> "${MKV_DESTINATION}temp_rawcooked_success.log"
success_count=$(grep -c '/mnt/' "${MKV_DESTINATION}temp_rawcooked_success.log")
echo "===================== Successful cooks: $success_count ===================== $DATE_FULL" >> "${MKV_DESTINATION}temp_rawcooked_success.log"

# Sort the log and remove any non-unique lines
cat "${MKV_DESTINATION}temp_rawcooked_success.log" | grep '/mnt/' | sort -r | uniq > "${MKV_DESTINATION}temp_rawcooked_success_unique.log"

# Remove temp lists, renewed when script restarts
rm "${MKV_DESTINATION}successful_mkv_list.txt"
rm "${MKV_DESTINATION}matroska_deletion_list.txt"
rm "${MKV_DESTINATION}matroska_deletion.txt"
rm "${MKV_DESTINATION}stale_encodings.txt"
rm "${MKV_DESTINATION}error_list.txt"

# Move the new log renaming it to overwrite the old log
mv "${MKV_DESTINATION}temp_rawcooked_success_unique.log" "${MKV_DESTINATION}rawcooked_success.log"
