#!/usr/bin/env bash
# MIT License
# Copyright 2025 R Baruch

set -euo pipefail
IFS=$'\n\t'

# ------------ Defaults ------------
INPUT_CSV_DEFAULT="user.csv"
OUTPUT_CSV_DEFAULT="cps_imports.csv"
GROUP_PRESET="basic"   # options: basic | none
ASSUME_YES="false"

# ------------ Helpers ------------
log()  { printf '[%s] %s\n' "$(date +'%Y-%m-%dT%H:%M:%S%z')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'USAGE'
Generate CPS import CSV from radioid.net user list (or a local CSV).

Usage:
  generate_cps_contact_format.sh [options]

Options:
  -i, --input FILE        Input CSV (default: user.csv). If missing, it will be downloaded.
  -o, --output FILE       Output CSV (default: cps_imports.csv)
  -y, --yes               Non-interactive: always refresh remote CSV if present
  -g, --groups PRESET     Group contacts preset: basic | none (default: basic)
  -h, --help              Show this help and exit

Notes:
  - Requires: gawk (for CSV-aware FPAT), and either curl or wget for downloads.
  - Private Call contacts are generated from the user CSV.
  - Group Call contacts are appended from the chosen preset deterministically.
USAGE
}

# ------------ Parse args ------------
INPUT_CSV="${INPUT_CSV_DEFAULT}"
OUTPUT_CSV="${OUTPUT_CSV_DEFAULT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)  INPUT_CSV="${2:-}"; shift 2 ;;
    -o|--output) OUTPUT_CSV="${2:-}"; shift 2 ;;
    -y|--yes)    ASSUME_YES="true"; shift ;;
    -g|--groups) GROUP_PRESET="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) die "Unknown argument: $1 (use -h for help)";;
  esac
done

# ------------ Dependency checks ------------
have gawk || die "gawk is required (for proper CSV parsing with FPAT). Install gawk and retry."
if ! have curl && ! have wget; then
  die "Need curl or wget for downloading."
fi

# ------------ Group presets ------------
# Deterministic, ordered TG list (edit safely here)
declare -a GROUP_NAMES=()
declare -a GROUP_IDS=()
case "${GROUP_PRESET}" in
  basic)
    GROUP_NAMES=( "TG.91" "TG.92" "TG.93" "TG.94" "TG.1" "TG.2" "TG.3" "TG.310" "TG.3124" "TG.3136" )
    GROUP_IDS=(   "91"    "92"    "93"    "94"    "1"    "2"    "3"    "310"   "3124"    "3136"   )
    ;;
  none)
    GROUP_NAMES=()
    GROUP_IDS=()
    ;;
  *)
    die "Unknown --groups preset: ${GROUP_PRESET} (use: basic | none)"
    ;;
esac
GROUP_COUNT="${#GROUP_NAMES[@]}"

# ------------ Download logic ------------
REMOTE_URL="https://radioid.net/static/user.csv"

download_atomic() {
  local url="$1" dest="$2"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  trap 'rm -f -- "${tmp}"' EXIT

  if have curl; then
    # Use -z to only download if newer when dest exists
    if [[ -f "${dest}" ]]; then
      curl -fsSLA "dmr-cps-import/1.0" --retry 3 --retry-delay 2 -z "${dest}" -o "${tmp}" "${url}" || true
      # If nothing downloaded (304), tmp may be empty; keep existing dest.
      if [[ ! -s "${tmp}" ]]; then
        log "Remote not newer; keeping existing ${dest}"
        rm -f -- "${tmp}"
        trap - EXIT
        return 0
      fi
    else
      curl -fsSLA "dmr-cps-import/1.0" --retry 3 --retry-delay 2 -o "${tmp}" "${url}"
    fi
  else
    # wget fallback (no built-in if-modified-since with file target in a single call)
    wget -q -O "${tmp}" "${url}"
  fi

  mv -f -- "${tmp}" "${dest}"
  trap - EXIT
  return 0
}

ensure_input_csv() {
  if [[ ! -f "${INPUT_CSV}" ]]; then
    log "Input CSV ${INPUT_CSV} not found; downloading fresh copy..."
    download_atomic "${REMOTE_URL}" "${INPUT_CSV}" || die "Download failed"
    log "Downloaded ${INPUT_CSV}"
  else
    if [[ "${ASSUME_YES}" == "true" ]]; then
      log "--yes set; refreshing ${INPUT_CSV} from remote…"
      download_atomic "${REMOTE_URL}" "${INPUT_CSV}" || die "Download failed"
      log "Refreshed ${INPUT_CSV}"
    else
      printf "%s exists. Fetch the latest from radioid.net? [y/N]: " "${INPUT_CSV}" >&2
      read -r answer || answer="n"
      if [[ "${answer}" =~ ^[Yy]$ ]]; then
        log "Refreshing ${INPUT_CSV}…"
        download_atomic "${REMOTE_URL}" "${INPUT_CSV}" || die "Download failed"
        log "Refreshed ${INPUT_CSV}"
      else
        log "Using existing ${INPUT_CSV}"
      fi
    fi
  fi
}

# ------------ Generate Output ------------
generate_output() {
  local in_csv="$1" out_csv="$2"

  # Header
  printf '"No","Call Alias","Call Type","Call ID","Receive Tone"\n' > "${out_csv}.tmp"

  # We need CSV-aware parsing:
  #
  # radioid user.csv format (commonly):
  #  id, callsign, fname, surname, city, state, country, ... (order may vary but id=$1, callsign=$2 in your original)
  #
  # Using gawk FPAT to treat quoted fields with commas as single fields.
  # We skip NR==1 (header). We output "Private Call" entries first with deterministic numbering.
  #
  # Step 1: Count data rows (excluding header) to know base for group numbering.
  local data_rows
  data_rows="$(gawk -v FPAT='([^,]*)|(\"([^\"]|\"\")*\")' 'NR>1 {c++} END{print c+0}' "${in_csv}")"

  # Step 2: Emit Private Call rows:
  # Alias: "(CALLSIGN)" same as your original
  # Numbering: 1..data_rows for private calls
  gawk -v FPAT='([^,]*)|(\"([^\"]|\"\")*\")' '
    NR==1 { next }  # skip header
    {
      id=$1; callsign=$2
      # trim surrounding quotes if present
      if (callsign ~ /^".*"$/) { sub(/^"/,"",callsign); sub(/"$/,"",callsign) }
      if (id ~ /^".*"$/)       { sub(/^"/,"",id);       sub(/"$/,"",id) }
      n++
      printf("\"%d\",\"(%s)\",\"Private Call\",%s,\"No\"\n", n, callsign, id)
    }
  ' "${in_csv}" >> "${out_csv}.tmp"

  # Step 3: Emit Group Call rows in fixed order after private calls
  if [[ "${GROUP_COUNT}" -gt 0 ]]; then
    local i
    local no
    no=$(( data_rows + 1 ))
    for (( i=0; i<GROUP_COUNT; i++ )); do
      # GROUP_NAMES[i] like "TG.91", GROUP_IDS[i] like "91"
      printf '"%d","%s","Group Call",%s,"No"\n' "${no}" "${GROUP_NAMES[i]}" "${GROUP_IDS[i]}" >> "${out_csv}.tmp"
      no=$(( no + 1 ))
    done
  fi

  mv -f -- "${out_csv}.tmp" "${out_csv}"
}

# ------------ Run ------------
ensure_input_csv
generate_output "${INPUT_CSV}" "${OUTPUT_CSV}"
log "Successfully generated ${OUTPUT_CSV}."
log "Next steps: import into Excel/LibreOffice and save as .xlsx for CPS DCS importing (if required by your CPS)."

