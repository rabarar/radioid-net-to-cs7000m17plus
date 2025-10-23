# radioid-net-to-cs7000m17plus

### Convert a radioid.net user.csv file into the format required for CS7000m17plus

```
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
```
### Convert csv file to xlsx

```
./csv2xlsx.py 
Usage: python script_name.py <input.csv> <output.xlsx>
```
