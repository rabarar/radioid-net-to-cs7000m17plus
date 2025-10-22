#!/usr/bin/env bash
# MIT License
# Copyright 2025 R Baruch

set -euo pipefail
IFS=$'\n\t'

# ------------ Defaults ------------
INPUT_CSV_DEFAULT="user.csv"
OUTPUT_CSV_DEFAULT="cps_imports.csv"
GROUP_PRESET="basic"   # options: basic | none | custom (custom is set automatically if --groups-file is used)
GROUPS_FILE=""         # if set, overrides preset
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
  -G, --groups-file FILE  CSV with group rows (name,id). Overrides --groups preset. Supports comments (#) and quotes.
  -h, --help              Show this help and exit

Notes:
  - Requires: gawk (for CSV-aware FPAT), and either curl or wget for downloads.
  - Private Call contacts are generated from the user CSV.
  - Group Call contacts are appended in deterministic order (preset or file order).
USAGE
}

# ------------ Parse args ------------
INPUT_CSV="${INPUT_CSV_DEFAULT}"
OUTPUT_CSV="${OUTPUT_CSV_DEFAULT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--input)        INPUT_CSV="${2:-}"; shift 2 ;;
    -o|--output)       OUTPUT_CSV="${2:-}"; shift 2 ;;
    -y|--yes)          ASSUME_YES="true"; shift ;;
    -g|--groups)       GROUP_PRESET="${2:-}"; shift 2 ;;
    -G|--groups-file)  GROUPS_FILE="${2:-}"; GROUP_PRESET="custom"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *) die "Unknown argument: $1 (use -h for help)";;
  esac
done 2>/dev/null || true
# shellcheck disable=SC2034 # (endesac line keeps zsh happy if used; harmless in bash)

# ------------ Dependency checks ------------
have gawk || die "gawk is required (for proper CSV parsing with FPAT). Install gawk and retry."
if ! have curl && ! have wget; then
  die "Need curl or wget for downloading."
fi

# ------------ Group presets (default) ------------
declare -a GROUP_NAMES=()
declare -a GROUP_IDS=()

load_preset_groups() {
  case "${GROUP_PRESET}" in
    basic)
      GROUP_NAMES=( "TG.91" "TG.92" "TG.93" "TG.94" "TG.1" "TG.2" "TG.3" "TG.310" "TG.3124" "TG.3136" )
      GROUP_IDS=(   "91"    "92"    "93"    "94"    "1"    "2"    "3"    "310"   "3124"    "3136"   )
      ;;
    none)
      GROUP_NAMES=()
      GROUP_IDS=()
      ;;
    custom)
      # Will be loaded from file later
      GROUP_NAMES=()
      GROUP_IDS=()
      ;;
    *)
      die "Unknown --groups preset: ${GROUP_PRESET} (use: basic | none | custom)"
      ;;
  esac
}

# ------------ Load groups from file ------------
# Format (CSV): name,id
# - Ignores empty lines and lines starting with '#'
# - Supports quoted fields with commas
load_groups_file() {
  local file="$1"
  [[ -f "$file" ]] || die "Groups file not found: $file"

  GROUP_NAMES=()
  GROUP_IDS=()

  # Parse with gawk FPAT to respect quotes; normalize and print "name,id" pairs
  while IFS=',' read -r gname gid; do
    # Trim whitespace
    gname="${gname#"${gname%%[![:space:]]*}"}"; gname="${gname%"${gname##*[![:space:]]}"}"
    gid="${gid#"${gid%%[![:space:]]*}"}";       gid="${gid%"${gid##*[![:space:]]}"}"
    [[ -z "$gname" || -z "$gid" ]] && continue
    GROUP_NAMES+=("$gname")
    GROUP_IDS+=("$gid")
  done < <(
    gawk -v FPAT='([^,]*)|(\"([^\"]|\"\")*\")' '
      /^[[:space:]]*#/ { next }
      NF==0            { next }
      {
        name=$1; id=$2
        # Strip outer quotes
        if (name ~ /^".*"$/) { sub(/^"/,"",name); sub(/"$/,"",name) }
        if (id   ~ /^".*"$/) { sub(/^"/,"",id);   sub(/"$/,"",id) }
        # Trim spaces
        sub(/^[[:space:]]+/,"",name); sub(/[[:space:]]+$/,"",name)
        sub(/^[[:space:]]+/,"",id);   sub(/[[:space:]]+$/,"",id)
        if (name != "" && id != "") print name "," id
      }' "$file"
  )

  validate_groups
  log "Loaded ${#GROUP_NAMES[@]} groups from ${file}."
}

validate_groups() {
  # match lengths
  if [[ "${#GROUP_NAMES[@]}" -ne "${#GROUP_IDS[@]}" ]]; then
    die "GROUP_NAMES and GROUP_IDS length mismatch (${#GROUP_NAMES[@]} vs ${#GROUP_IDS[@]})"
  fi

  local i j name id
  for (( i=0; i<${#GROUP_NAMES[@]}; i++ )); do
    name="${GROUP_NAMES[i]}"
    id="${GROUP_IDS[i]}"

    # non-empty name
    if [[ -z "$name" ]]; then
      die "Empty group name at row $((i+1))"
    fi
    # numeric ID (Bash 3.2 supports =~)
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
      die "Non-numeric group ID '${id}' at row $((i+1))"
    fi

    # Duplicate detection without associative arrays
    for (( j=i+1; j<${#GROUP_NAMES[@]}; j++ )); do
      if [[ "${GROUP_NAMES[j]}" == "$name" ]]; then
        die "Duplicate group name '${name}' (rows $((i+1)) and $((j+1)))"
      fi
      if [[ "${GROUP_IDS[j]}" == "$id" ]]; then
        log "Warning: duplicate group ID '${id}' (rows $((i+1)) and $((j+1))); continuing"
      fi
    done
  done
}

# ------------ Download logic ------------
REMOTE_URL="https://radioid.net/static/user.csv"

download_atomic() {
  local url="$1" dest="$2"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  trap 'rm -f -- "${tmp}"' EXIT

  if have curl; then
    if [[ -f "${dest}" ]]; then
      curl -fsSLA "dmr-cps-import/1.0" --retry 3 --retry-delay 2 -z "${dest}" -o "${tmp}" "${url}" || true
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

  # Count data rows (excluding header)
  local data_rows
  data_rows="$(gawk -v FPAT='([^,]*)|(\"([^\"]|\"\")*\")' 'NR>1 {c++} END{print c+0}' "${in_csv}")"

  # Private Call rows: 1..data_rows
  gawk -v FPAT='([^,]*)|(\"([^\"]|\"\")*\")' '
    NR==1 { next }  # skip header
    {
      id=$1; callsign=$2
      if (callsign ~ /^".*"$/) { sub(/^"/,"",callsign); sub(/"$/,"",callsign) }
      if (id ~ /^".*"$/)       { sub(/^"/,"",id);       sub(/"$/,"",id) }
      n++
      printf("\"%d\",\"(%s)\",\"Private Call\",%s,\"No\"\n", n, callsign, id)
    }
  ' "${in_csv}" >> "${out_csv}.tmp"

  # Group Call rows in deterministic order after private calls
  validate_groups
  if (( ${#GROUP_NAMES[@]} > 0 )); then
    local no=$(( data_rows + 1 ))
    local i
    for (( i=0; i<${#GROUP_NAMES[@]}; i++ )); do
      printf '"%d","%s","Group Call",%s,"No"\n' "$no" "${GROUP_NAMES[i]}" "${GROUP_IDS[i]}" >> "${out_csv}.tmp"
      (( no++ ))
    done
    log "Appended ${#GROUP_NAMES[@]} Group Call rows after ${data_rows} Private Call rows."
  else
    log "No Group Calls configured."
  fi

  mv -f -- "${out_csv}.tmp" "${out_csv}"
}

# ------------ Run ------------
load_preset_groups
if [[ -n "${GROUPS_FILE}" ]]; then
  load_groups_file "${GROUPS_FILE}"
fi

ensure_input_csv
generate_output "${INPUT_CSV}" "${OUTPUT_CSV}"
log "Successfully generated ${OUTPUT_CSV}."
log "Next steps: import into Excel/LibreOffice and save as .xlsx for CPS DCS importing (if required by your CPS)."

