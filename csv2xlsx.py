#!/Users/robert/.virtualenvs/csv2xlsx/bin/python

import sys
import pandas as pd

def csv_to_xlsx(csv_file, xlsx_file):
    """
    Reads a CSV file and writes its contents to an Excel (.xlsx) file.

    Args:
        csv_file (str): The path to the input CSV file.
        xlsx_file (str): The path to the output XLSX file.
    """
    try:
        # Read the CSV file into a pandas DataFrame
        df = pd.read_csv(csv_file)
        
        # Write the DataFrame to an Excel file
        # index=False prevents pandas from writing the DataFrame index as a column
        df.to_excel(xlsx_file, index=False)
        
        print(f"Successfully converted '{csv_file}' to '{xlsx_file}'")
    except FileNotFoundError:
        print(f"Error: The file '{csv_file}' was not found.")
    except Exception as e:
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    # Check for the correct number of command-line arguments
    if len(sys.argv) != 3:
        print("Usage: python script_name.py <input.csv> <output.xlsx>")
        sys.exit(1)

    # Assign command-line arguments to variables
    # The arguments are accessed from the sys.argv list by index.
    # sys.argv[0] is the script name.
    # sys.argv[1] is the first argument (input file).
    # sys.argv[2] is the second argument (output file).
    input_csv = sys.argv[1]
    output_xlsx = sys.argv[2]

    print("input =" +input_csv)
    print("output =" +output_xlsx)
    # Perform the conversion
    csv_to_xlsx(input_csv, output_xlsx)

