#!/bin/bash
# Stop on command failures, unset variables, and failures inside pipelines.
set -euo pipefail

# Locate this script's repository independently of the caller's working directory.
repo_dir="$(cd "$(dirname "$0")" && pwd)"

usage() {
    printf 'Usage: %s --dataset {1pct_flt3_filtered|full_size_flt3_filtered} [--mode {baseline|scalene}] [--run-name NAME]\n' "$0"
}

dataset=""
run_name=""
mode="scalene"
while (($#)); do
    case "$1" in
        --dataset)
            if [[ $# -lt 2 ]]; then
                printf 'Missing value for --dataset\n' >&2
                usage >&2
                exit 2
            fi
            dataset="$2"
            shift 2
            ;;
        --run-name)
            if [[ $# -lt 2 ]]; then
                printf 'Missing value for --run-name\n' >&2
                usage >&2
                exit 2
            fi
            if [[ -z "$2" ]]; then
                printf 'Run name cannot be empty\n' >&2
                usage >&2
                exit 2
            fi
            run_name="$2"
            shift 2
            ;;
        --mode)
            if [[ $# -lt 2 ]]; then
                printf 'Missing value for --mode\n' >&2
                usage >&2
                exit 2
            fi
            mode="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$dataset" ]]; then
    printf 'Choose an input dataset with --dataset\n' >&2
    usage >&2
    exit 2
fi

if [[ -n "$run_name" && ( "$run_name" == "." || "$run_name" == ".." || "$run_name" == */* ) ]]; then
    printf 'Run name must be a single directory name, not a path: %s\n' "$run_name" >&2
    exit 2
fi

case "$dataset" in
    1pct_flt3_filtered|full_size_flt3_filtered)
        dataset_dir="$repo_dir/test/data/$dataset"
        ;;
    *)
        printf 'Unknown dataset: %s\n' "$dataset" >&2
        usage >&2
        exit 2
        ;;
esac

# Profiling and getITD settings not exposed as command-line options.
python="$repo_dir/.venv-profile/bin/python"
forward="$dataset_dir/26NM-231D00526-1.R1.fastq.gz"
reverse="$dataset_dir/26NM-231D00526-1.R2.fastq.gz"
# Alignment sequence and coordinate annotation are separate inputs.
reference="$repo_dir/anno/amplicon.txt"
annotation="/Users/NM346413/Development/heme-mrd-pipeline/scripts/hg38_liftover_amplicon_kayser.tsv"
# Sample ID names getITD's output directory within each unique run directory.
sample_id="26NM-231D00526-1"
results_dir="$repo_dir/test/output/profiles"
# Set the number of threads for parallel processing.
workers=8
# Refresh the JSON capture during long runs; this is not a history of snapshots.
profile_interval_seconds=60
# Pipeline settings: retain single-copy reads, allow trimmed primers, infer strand.
min_read_copies=1
require_indel_free_primers="False"
infer_sense_from_alignment="True"
# Enable diagnostic per-read START/DONE records for this profiling run.
log_alignment_progress="True"
# END CONFIGURATION.

# Resolve input paths before changing directories so relative arguments still work.
forward="$(cd "$(dirname "$forward")" && pwd)/$(basename "$forward")"
reverse="$(cd "$(dirname "$reverse")" && pwd)/$(basename "$reverse")"
reference="$(cd "$(dirname "$reference")" && pwd)/$(basename "$reference")"
annotation="$(cd "$(dirname "$annotation")" && pwd)/$(basename "$annotation")"
# Create and resolve the results root before getITD changes working directories.
mkdir -p "$results_dir"
results_dir="$(cd "$results_dir" && pwd)"
# Fail early for unreadable inputs, invalid worker counts/modes, or missing Python.
for input in "$forward" "$reverse" "$reference" "$annotation"; do
    [[ -r "$input" ]] || { printf 'Cannot read %s\n' "$input" >&2; exit 2; }
done
[[ "$workers" =~ ^[1-9][0-9]*$ ]] || { printf 'Workers must be positive\n' >&2; exit 2; }
[[ "$profile_interval_seconds" =~ ^[1-9][0-9]*$ ]] || { printf 'Profile interval must be positive\n' >&2; exit 2; }
case "$mode" in
    baseline|scalene) ;;
    *) printf 'Mode must be baseline or scalene\n' >&2; exit 2 ;;
esac
[[ -x "$python" ]] || { printf 'Python not found: %s\n' "$python" >&2; exit 2; }

# Use a caller-provided name when supplied; otherwise create a unique name.
# Never reuse a directory, so an explicit name cannot overwrite prior results.
if [[ -n "$run_name" ]]; then
    run_dir="$results_dir/$run_name"
    if ! mkdir "$run_dir"; then
        printf 'Cannot create run directory (it may already exist): %s\n' "$run_dir" >&2
        exit 2
    fi
else
    # mktemp replaces the X characters with a unique suffix.
    run_dir="$(mktemp -d "$results_dir/${mode}-${dataset}-${workers}workers-XXXXXXXX")"
fi
printf 'Results: %s\n' "$run_dir"
# getITD creates its sample output directory relative to this working directory.
cd "$run_dir"
# Preserve the selected dataset and exact input paths alongside the profile.
{
    printf 'dataset=%s\n' "$dataset"
    printf 'mode=%s\n' "$mode"
    printf 'R1=%s\n' "$forward"
    printf 'R2=%s\n' "$reverse"
} > dataset.txt
# Use headless plotting and flush Python output promptly into the run log.
export MPLBACKEND=Agg PYTHONUNBUFFERED=1
# Record interpreter and package versions for comparisons between profiling runs.
"$python" --version > environment.txt
"$python" -m pip freeze >> environment.txt
# Build a Bash array so spaces in paths remain part of a single argument.
command=("$python")
# In profiling mode, launch getITD through Scalene and retain the raw JSON report.
if [[ "$mode" == scalene ]]; then
    command+=(-m scalene run --profile-interval "$profile_interval_seconds"
        --outfile "$run_dir/scalene-profile.json")
fi
command+=("$repo_dir/getitd.py")
# Scalene's separator forwards subsequent options to getITD rather than Scalene.
if [[ "$mode" == scalene ]]; then
    command+=(---)
fi
# Pass the configured reference, annotation, and analysis settings to getITD.
command+=(
    -reference "$reference"
    -anno "$annotation" -nkern "$workers"
    -min_read_copies "$min_read_copies" -require_indel_free_primers "$require_indel_free_primers"
    -infer_sense_from_alignment "$infer_sense_from_alignment"
    -log_alignment_progress "$log_alignment_progress"
    "$sample_id" "$forward" "$reverse")
# Save a shell-escaped command that can be inspected or rerun from this directory.
printf '%q ' "${command[@]}" > command.txt
printf '\n' >> command.txt
# macOS time reports elapsed/user/system time, maximum RSS, and block-I/O counters.
# These are not file-level I/O timings or a sampled total RSS across all workers.
# resources.txt also receives program warnings/errors; stdout goes to run.log.
# Scalene adds overhead, so use baseline mode for an uninstrumented comparison.
# Ctrl+C reaches the foreground profiler and workers. Keep the shell alive to
# render the saved capture after Scalene has finished handling the interrupt.
interrupted=0
if [[ "$mode" == scalene ]]; then
    trap 'interrupted=1; printf "\nInterrupted; waiting for Scalene to save its profile.\n"' INT
    printf 'Running with Scalene; press Ctrl+C once to stop and save the profile.\n'
else
    trap 'interrupted=1; printf "\nInterrupted; waiting for getITD to stop.\n"' INT
    printf 'Running without Scalene; press Ctrl+C to stop.\n'
fi
exit_code=0
if /usr/bin/time -l "${command[@]}" > run.log 2> resources.txt; then
    exit_code=0
else
    exit_code=$?
fi
trap - INT
# Scalene may handle KeyboardInterrupt successfully and return zero.
if [[ "$interrupted" == 1 && "$exit_code" == 0 ]]; then
    exit_code=130
fi
printf '%s\n' "$exit_code" > exit_code.txt
# Convert the JSON capture into a self-contained HTML report without opening a browser.
# Report rendering happens after the timed command and is not included in its totals.
# On interruption or failure, an earlier periodic capture may be all that is available.
if [[ "$mode" == scalene ]]; then
    if [[ -s "$run_dir/scalene-profile.json" ]]; then
        if ! "$python" -m scalene view --standalone "$run_dir/scalene-profile.json"; then
            printf 'HTML rendering failed; inspect the saved JSON and resources.txt.\n' >&2
            if [[ "$exit_code" == 0 ]]; then
                exit_code=1
            fi
        fi
    else
        printf 'No profile was saved; inspect resources.txt for details.\n' >&2
        if [[ "$exit_code" == 0 ]]; then
            exit_code=1
        fi
    fi
fi
# Print the results location again when the run and optional rendering finish.
printf 'Finished (exit %s): %s\n' "$exit_code" "$run_dir"
exit "$exit_code"