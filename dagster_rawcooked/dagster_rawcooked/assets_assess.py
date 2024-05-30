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
import dpx_assess
import sqlite_funcs
import dpx_seq_gap_check
from .config import DOWNTIME, DATABASE, QNAP_FILM, ASSESS, DPX_COOK, MKV_ENCODED, DPOLICY, DPX_REVIEW


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
    dpx_seq = os.path.split(dpx_path)
    context.log.info(f"Processing DPX sequence: {dpx_path}")

    part, whole = dpx_assess.get_partwhole(dpx_seq)
    if not part:
        sqlite_funcs.update_table(dpx_seq, f'DPX sequence named incorrectly.', DATABASE)
        return {"status": "partWhole failure", "dpx_seq": dpx_path}        
    context.log.info(f"* Reel number {str(part).zfill(2)} of {str(whole).zfill(2)}")

    folder_depth = dpx_assess.check_folder_depth(dpx_path)
    if folder_depth is None:
        # Incorrect formatting of folders
        sqlite_funcs.update_table(dpx_seq, f'Folders formatted incorrectly.', DATABASE)
        return {"status": "folder failure", "dpx_seq": dpx_path}
    context.log.info(f"Folder depth is {folder_depth}")

    gaps, missing = dpx_seq_gap_check.gaps(dpx_path)
    if gaps is True:
        context.log.info(f"Gaps found in sequence,moving to dpx_review folder: {missing}")
        review_path = os.path.join(QNAP_FILM, DPX_REVIEW, dpx_seq)
        shutil.move(dpx_path, review_path)
        sqlite_funcs.update_table(dpx_seq, f'Gaps found in sequence: {missing}.', DATABASE)
        return {"status": "gaps", "dpx_seq": dpx_path}

    size, cspace, bitdepth = dpx_assess.get_metadata(dpx_path)
    context.log.info(f"* Size: {size} | Colourspace {cspace} | Bit-depth {bitdepth}")
    policy_pass = dpx_assess.mediaconch(dpx_path, DPOLICY)
    context.log.info(f"* DPX policy status: {policy_pass}")
    if not policy_pass:
        context.log.info(f"DPX sequence {dpx_seq} failed DPX policy: {dpx_path}")
        # Move to tar wrap into splitting if needed
        # Exit
    else:
        return {"status": "split rawcook", "dpx_seq": dpx_path, "size": size}


@asset
def handle_assessments(assessment):
    '''
    Move to splittig or to encoding
    by updating sqlite data and trigger
    splitting.py (next asset scripts)
    '''
    if assessment['status'] ==  'gaps':
        pass
    elif assessment['status'] == 'tar':
        # Move to tar wrap path
        pass
    elif assessment['status'] == 'rawcook':
        # Move to RAWcooked path
        pass
    elif assessment['status'] == 'split tar':
        # Initiate splitting with tar argument
        pass
    elif assessment['status'] == 'split rawcook':
        # Initiate splitting with rawcook argument
        pass

