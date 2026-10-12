# MSR to PDF Converter

This utility converts `.msr` files into PDF reports with graphs.

## Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/your-username/msr-to-pdf.git
   cd msr-to-pdf
   ```

2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

## Usage

Run the shell script and provide the `.msr` files or a folder containing them:

```bash
chmod +x msr_to_pdf.sh
./msr_to_pdf.sh file1.msr file2.msr
# OR
./msr_to_pdf.sh path/to/folder
```

The script will ask you for a name for the output folder where the generated PDFs will be saved.

## Files
- `msr_to_pdf.sh`: Bash wrapper for easy usage.
- `msr_to_pdf.py`: The core Python logic for conversion.
- `requirements.txt`: List of required Python libraries.
