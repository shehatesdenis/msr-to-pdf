# MSR to PDF Converter

This utility converts `.msr` (PHYWE measure 4) files into high-quality PDF reports with graphs.

## 🚀 Quick Start

The tool is designed to be completely autonomous. You only need the shell script to get started.

### For macOS and Linux:
1. **Download the script:**
   ```bash
   curl -O https://raw.githubusercontent.com/shehatesdenis/msr-to-pdf/main/msr_to_pdf.sh
   ```

2. **Make it executable:**
   ```bash
   chmod +x msr_to_pdf.sh
   ```

3. **Run it:**
   ```bash
   ./msr_to_pdf.sh your_file.msr
   # OR
   ./msr_to_pdf.sh path/to/folder_with_msr
   ```

## 🛠 How it works

You don't need to manually install Python libraries or clone the whole repo. When you run the `.sh` script:
1. It checks if **Python 3** is installed on your system.
2. It automatically installs necessary dependencies (like `matplotlib`) via `pip`.
3. It extracts the embedded Python converter logic into a local file.
4. It processes your `.msr` files and asks you for a folder name to save the resulting PDFs.

## 📋 Requirements

- **Python 3** must be installed on your system.
- **pip** (Python package manager) should be available for automatic dependency installation.

## 📁 Files
- `msr_to_pdf.sh`: The only file you need. It contains both the Bash wrapper and the embedded Python conversion engine.
