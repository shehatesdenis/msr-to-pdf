#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_CONVERTER="${SCRIPT_DIR}/msr_to_pdf.py"

usage() {
  cat <<'EOF'
Использование:
  ./msr_to_pdf.sh файл.msr
  ./msr_to_pdf.sh файл1.msr файл2.msr ...
  ./msr_to_pdf.sh папка_с_msr

Скрипт спросит имя папки, создаст её рядом с собой
и сохранит туда PDF с теми же именами, что у .msr.
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

if [[ ! -f "$PYTHON_CONVERTER" ]]; then
  echo "Не найден конвертер: $PYTHON_CONVERTER" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Нужен python3." >&2
  exit 1
fi

inputs=()
for arg in "$@"; do
  if [[ ! -e "$arg" ]]; then
    echo "Не найден путь: $arg" >&2
    exit 1
  fi
  inputs+=("$(cd "$(dirname "$arg")" && pwd)/$(basename "$arg")")
done

has_msr=0
for path in "${inputs[@]}"; do
  if [[ -f "$path" ]]; then
    ext="${path##*.}"
    ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    if [[ "$ext" == "msr" ]]; then
      has_msr=1
      break
    fi
  elif [[ -d "$path" ]]; then
    if find "$path" -iname '*.msr' | head -n 1 | grep -q .; then
      has_msr=1
      break
    fi
  fi
done

if [[ "$has_msr" -eq 0 ]]; then
  echo "Среди аргументов нет файлов .msr." >&2
  exit 1
fi

printf "Как назвать папку, куда выгрузить PDF? "
IFS= read -r folder_name

folder_name="$(printf '%s' "$folder_name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
if [[ -z "$folder_name" ]]; then
  echo "Имя папки не может быть пустым." >&2
  exit 1
fi
if [[ "$folder_name" == *"/"* || "$folder_name" == *"\\"* || "$folder_name" == "." || "$folder_name" == ".." ]]; then
  echo "Укажите только имя папки, без пути." >&2
  exit 1
fi

output_dir="${SCRIPT_DIR}/${folder_name}"
if [[ -e "$output_dir" && ! -d "$output_dir" ]]; then
  echo "Путь уже существует и это не папка: $output_dir" >&2
  exit 1
fi
mkdir -p "$output_dir"

export MPLCONFIGDIR="$(mktemp -d "${TMPDIR:-/tmp}/msr-to-pdf.XXXXXX")"
trap 'rm -rf "$MPLCONFIGDIR"' EXIT

failed=0
for path in "${inputs[@]}"; do
  if ! python3 "$PYTHON_CONVERTER" "$path" -o "$output_dir"; then
    failed=1
  fi
done

if [[ "$failed" -ne 0 ]]; then
  echo "Часть файлов не удалось преобразовать. PDF, которые получились, лежат в:" >&2
  echo "  $output_dir" >&2
  exit 1
fi

echo "Готово. PDF сохранены в:"
echo "  $output_dir"
