'''
dagster_rawcooked/assess.py
Links together all python code
for RAWcooked assessment calling
in external module from dpx_assess
as needed. Move for splitting.

NOTE: Need splitting path so assess.py
doesn't pick up for repeat assessment

Joanna White
2024
'''

# Imports
import os
import sys
import json
import shutil
from dagster import asset, DynamicOutput
from .dpx_assess import get_partwhole, count_folder_depth, get_metadata, get_mediaconch, get_folder_size
from .sqlite_funcs import create_first_entry, update_table
from .dpx_seq_gap_check import gaps
from .dpx_splitting import launch_splitting
from .config import DOWNTIME, DATABASE, QNAP_FILM, ASSESS, DPX_COOK, MKV_ENCODED, DPOLICY, DPX_REVIEW, PART_RAWCOOK, PART_TAR, TAR_WRAP


def check_control():
    '''
    Check control json for downtime requests
    '''
    with open(DOWNTIME) as control:
        j = json.load(control)
        if not j['rawcooked']:
            sys.exit("Downtime control close")


@asset
def get_dpx_folders():
    '''
    Retrieve list of DPX subfolders
    extract items partially processed
    '''
    dpx_folder = os.path.join(QNAP_FILM, ASSESS)
    mkv_folder = os.path.join(QNAP_FILM, MKV_ENCODED, 'mkv_cooked')

    dpx_folders = [x for x in os.listdir(dpx_folder) if os.path.isdir(os.path.join(dpx_folder, x))]
    mkv_processing = [x for x in os.listdir(mkv_folder) if x.endswith('.mkv.txt')]

    for file in mkv_processing:
        mkv = file.split('.')[0]
        if mkv in dpx_folders:
            dpx_folders.remove(mkv)

    return dpx_folders


@asset(
    config_schema={"dpx_path": str},
    required_resource_keys={"dpx_path"}
)


@asset
def dynamic_process_subfolders(get_dpx_folders):
    ''' Push get_dpx_folder list to multiple assets'''
    for dpx_folder in get_dpx_folders:
        dpath = os.path.join(QNAP_FILM, DPX_COOK, dpx_folder)
        yield DynamicOutput(dpath, mapping_key=dpx_folder)


@asset
def assessment(context, dynamic_process_subfolders):
    ''' Calling dpx_assess modules run assessment '''
    dpx_path = dynamic_process_subfolders
    dpx_seq = os.path.split(dpx_path)[1]
    context.log.info(f"Processing DPX sequence: {dpx_path}")

    part, whole = get_partwhole(dpx_seq)
    if not part:
        row_id = update_table('status', dpx_seq, f'Fail! DPX sequence named incorrectly.')
        if not row_id:
            context.log.warning("Failed to update status with 'DPX sequence named incorrectly'")
            return {"status": "database failure", "dpx_seq": dpx_path}
        return {"status": "partWhole failure", "dpx_seq": dpx_path}        
    context.log.info(f"* Reel number {str(part).zfill(2)} of {str(whole).zfill(2)}")

    folder_depth, first_dpx = count_folder_depth(dpx_path)
    if folder_depth is None:
        # Incorrect formatting of folders
        row_id = update_table('status', dpx_seq, f'Fail! Folders formatted incorrectly.')
        if not row_id:
            context.log.warning("Failed to update status with 'Folders formatted incorrectly'")
            return {"status": "database failure", "dpx_seq": dpx_path}
        return {"status": "folder failure", "dpx_seq": dpx_path}
    context.log.info(f"Folder depth is {folder_depth}")

    gaps, missing, first_dpx = gaps(dpx_path)
    if gaps is True:
        context.log.info(f"Gaps found in sequence,moving to dpx_review folder: {missing}")
        review_path = os.path.join(QNAP_FILM, DPX_REVIEW, dpx_seq)
        shutil.move(dpx_path, review_path)
        row_id = update_table('status', dpx_seq, f'Fail! Gaps found in sequence: {missing}.')
        if not row_id:
            context.log.warning(f"Failed to update status with 'Gaps found in sequence'\n{missing}")
        return {"status": "gap failure", "dpx_seq": dpx_path}

    size = get_folder_size(dpx_path)
    cspace = get_metadata('Video', 'ColorSpace', first_dpx)
    bdepth = get_metadata('Video', 'BitDepth', first_dpx)
    width = get_metadata('Video', 'Width', first_dpx)
    if not cspace:
        cspace = get_metadata('Image', 'ColorSpace', first_dpx)
    if not bdepth:
        bdepth = get_metadata('Image', 'BitDepth', first_dpx)
    if not width:
        width = get_metadata('Image', 'Width', first_dpx)

    tar = fourk = luma = False
    context.log.info(f"* Size: {size} | Colourspace {cspace} | Bit-depth {bdepth} | Pixel width {width}")
    policy_pass, response = get_mediaconch(dpx_path, DPOLICY)

    if not policy_pass:
        tar = True
        context.log.info(f"DPX sequence {dpx_seq} failed DPX policy:\n{response}")
    if int(width) > 3999:
        fourk = True
        context.log.info(f"DPX sequence {dpx_seq} is 4K")
    if 'Y' == cspace:
        luma = True
    if tar is True:
        row_id = create_first_entry(dpx_seq, cspace, size, bdepth, 'Ready for split assessment', 'tar', dpx_path)
        if not row_id:
            context.log.warning(f"Failed to update status new reord data")
            return {"status": "database failure", "dpx_seq": dpx_path}
        return {"status": "tar", "dpx_seq": dpx_path, "size": size, "4k": fourk, "luma": luma, "part": part, "whole": whole}
    else:
        row_id = create_first_entry(dpx_seq, cspace, size, bdepth, 'Ready for split assessment', 'rawcook', dpx_path)
        if not row_id:
            context.log.warning(f"Failed to update status new reord data")
            return {"status": "database failure", "dpx_seq": dpx_path}
        return {"status": "rawcook", "dpx_seq": dpx_path, "size": size, "4k": fourk, "luma": luma, "part": part, "whole": whole}


@asset
def move_for_split_or_encoding(context, assessment):
    '''
    Move to splittig or to encoding
    by updating sqlite data and trigger
    splitting.py (next asset scripts)
    '''
    if 'failure' not in assessment['status']:
        if assessment['size'] > 1395864370:
            reels = launch_splitting(assessment['dpx_seq'])
            if 'failure' in reels['status']:
                raise Exception("Reels were not split correctly. Exiting")
            if assessment['status'] == 'rawcook':
                for reel in reels['paths']:
                    context.log.info(f"Moving reel {reel} to {PART_RAWCOOK}")
                    shutil.move(reel, os.path.join(QNAP_FILM, PART_RAWCOOK))
            elif assessment['status'] == 'tar':
                for reel in reels:
                    context.log.info(f"Moving reel {reel} to {PART_TAR}")
                    shutil.move(reel, os.path.join(QNAP_FILM, PART_TAR))
        if int(assessment['whole']) == 1:
            context.log.info(f"Moving single reel under 1TB to encoding path")
            if assessment['status'] == 'rawcook':
                shutil.move(assessment['dpx_seq'], os.path.join(QNAP_FILM, DPX_COOK))         
            elif assessment['status'] == 'tar':
                shutil.move(assessment['dpx_seq'], os.path.join(QNAP_FILM, TAR_WRAP))