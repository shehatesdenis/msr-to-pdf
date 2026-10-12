#!/usr/bin/env bash
set -euo pipefail

# --- CONFIGURATION ---
PYTHON_CONVERTER="msr_to_pdf.py"
REQUIRED_PACKAGES=("matplotlib")

# --- HELPER FUNCTIONS ---
usage() {
  cat <<'EOF'
Использование:
  ./msr_to_pdf.sh файл.msr
  ./msr_to_pdf.sh файл1.msr файл2.msr ...
  ./msr_to_pdf.sh папка_с_msr

Скрипт автоматически установит зависимости, если они отсутствуют,
создаст папку для выгрузки и сохранит туда PDF.
EOF
}

# 1. Check for Python 3
if ! command -v python3 >/dev/null 2>&1; then
  echo "Ошибка: Не установлен python3. Пожалуйста, установите его." >&2
  exit 1
fi

# 2. Ensure Python converter exists (embedded)
if [[ ! -f "$PYTHON_CONVERTER" ]]; then
  echo "Подготовка конвертера..."
  cat <<'EOF_PY' > "$PYTHON_CONVERTER"
#!/usr/bin/env python3
"""Convert PHYWE measure 4 (.msr) recordings to PDF plots."""

from __future__ import annotations

import argparse
import struct
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

MAGIC = b"\x19\x05\x06\x07\x08\tmeasure45 FileFormat"
DATA_OFFSET = 0x370
SAMPLE_COUNT_OFFSET = 0x44
DATETIME_OFFSET = 0x2C
CHANNEL_BLOCK_PREFIX = b"\x02\x00\x98\x00\x00\x00"

@dataclass
class Channel:
    name: str
    unit: str
    symbol: str
    values: list[float]

@dataclass
class Measurement:
    path: Path
    title: str
    instrument: str
    recorded_at: datetime | None
    n_samples: int
    channels: list[Channel] = field(default_factory=list)

    def channel(self, symbol: str) -> Channel | None:
        symbol = symbol.lower()
        for ch in self.channels:
            if ch.symbol.lower() == symbol:
                return ch
        return None

def _u16(data: bytes, offset: int) -> int:
    return struct.unpack_from("<H", data, offset)[0]

def _u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]

def _f32(data: bytes, offset: int) -> float:
    return struct.unpack_from("<f", data, offset)[0]

def _f64(data: bytes, offset: int) -> float:
    return struct.unpack_from("<d", data, offset)[0]

def _utf16_at(data: bytes, offset: int) -> tuple[str, int] | None:
    if offset + 8 > len(data):
        return None
    length = _u32(data, offset + 2)
    if length < 2 or length > 400 or length % 2 or offset + 8 + length > len(data):
        return None
    raw = data[offset + 8 : offset + 8 + length]
    try:
        text = raw.decode("utf-16le")
    except UnicodeDecodeError:
        return None
    if "\x00" in text:
        return None
    if not any(ch.isalpha() or ord(ch) > 127 for ch in text):
        return None
    return text, offset + 8 + length

def _delphi_datetime(value: float) -> datetime | None:
    if not (20000 < value < 80000):
        return None
    try:
        return datetime(1899, 12, 30) + timedelta(days=value)
    except OverflowError:
        return None

def _read_floats(data: bytes, offset: int, count: int) -> list[float]:
    end = offset + count * 4
    if end > len(data):
        raise ValueError("truncated float array")
    return list(struct.unpack_from(f"<{count}f", data, offset))

def parse_msr(path: Path) -> Measurement:
    data = path.read_bytes()
    if not data.startswith(MAGIC):
        raise ValueError(f"not a PHYWE measure45 file: {path}")

    n_samples = _u32(data, SAMPLE_COUNT_OFFSET)
    if n_samples < 2 or n_samples > 1_000_000:
        raise ValueError(f"unreasonable sample count {n_samples} in {path}")

    recorded_at = _delphi_datetime(_f64(data, DATETIME_OFFSET))

    strings: dict[int, str] = {}
    offset = 0x80
    while offset + 8 < DATA_OFFSET:
        parsed = _utf16_at(data, offset)
        if parsed is None:
            offset += 2
            continue
        tag = _u16(data, offset)
        text, next_offset = parsed
        strings[tag] = text
        offset = next_offset

    n_channels = _u16(data, DATA_OFFSET)
    nbytes = _u32(data, DATA_OFFSET + 2)
    if nbytes != n_samples * 4:
        raise ValueError(f"channel byte size {nbytes} does not match n*4={n_samples * 4} in {path}")
    if n_channels < 1:
        raise ValueError(f"no channels in {path}")

    planes_start = DATA_OFFSET + 8
    planes = [_read_floats(data, planes_start + i * n_samples * 4, n_samples) for i in range(n_channels)]

    values: list[list[float]] = [planes[0]]
    if n_channels >= 2:
        spilled = planes[2][:2] if n_channels >= 3 else []
        values.append(planes[1][2:] + spilled)
    if n_channels >= 3:
        footer = _read_floats(data, planes_start + 3 * n_samples * 4, 4)
        values.append(planes[2][4:] + footer)

    meta = [
        (strings.get(0x09, "Расстояние"), strings.get(0x0A, "cm"), strings.get(0x0B, "s")),
        (strings.get(0x0C, "Плотность пото B"), strings.get(0x0D, "mT"), strings.get(0x0E, "B")),
        (strings.get(0x0F, "Ток"), strings.get(0x10, "A"), strings.get(0x11, "I")),
    ]

    channels = [
        Channel(name=meta[i][0], unit=meta[i][1], symbol=meta[i][2], values=values[i])
        for i in range(min(n_channels, len(values), len(meta)))
        if len(values[i]) == n_samples
    ]
    if len(channels) < 2:
        raise ValueError(f"could not reconstruct X/Y series in {path}")

    return Measurement(
        path=path,
        title=strings.get(0x06) or path.stem,
        instrument=strings.get(0x07, ""),
        recorded_at=recorded_at,
        n_samples=n_samples,
        channels=channels,
    )

def _axis_label(channel: Channel) -> str:
    symbol = channel.symbol or channel.name
    unit = channel.unit
    if unit:
        return f"{symbol} / {unit}"
    return symbol

def plot_measurement(measurement: Measurement, ax: plt.Axes) -> None:
    x_ch = measurement.channel("s") or measurement.channels[0]
    y_ch = measurement.channel("B") or measurement.channels[1]
    x = x_ch.values
    y = y_ch.values

    ax.plot(x, y, color="#e10600", linewidth=1.4, label=y_ch.name)
    ax.set_xlabel(_axis_label(x_ch), loc="right", fontsize=12)
    ax.set_ylabel(_axis_label(y_ch), fontsize=12)
    ax.grid(True, which="major", color="#c8c8c8", linewidth=0.6)
    ax.set_axisbelow(True)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    ax.tick_params(direction="out", labelsize=9)
    ax.set_title(measurement.path.stem, fontsize=14, pad=10)

    info = []
    if measurement.instrument:
        info.append(measurement.instrument)
    if measurement.recorded_at:
        info.append(measurement.recorded_at.strftime("%Y-%m-%d %H:%M:%S"))
    i_ch = measurement.channel("I")
    if i_ch and i_ch.values:
        current = sum(i_ch.values) / len(i_ch.values)
        info.append(f"{i_ch.symbol} ≈ {current:.3f} {i_ch.unit}")
    if info:
        ax.text(0.99, 0.02, "  ·  ".join(info), transform=ax.transAxes, ha="right", va="bottom", fontsize=8, color="#555555")
    ax.legend(loc="upper right", frameon=True, fancybox=False, framealpha=0.95, fontsize=9)

def render_pdf(measurement: Measurement, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    fig, ax = plt.subplots(figsize=(11.69, 8.27))
    plot_measurement(measurement, ax)
    fig.tight_layout()
    fig.savefig(output, format="pdf")
    plt.close(fig)

def find_msr_files(root: Path) -> list[Path]:
    if root.is_file() and root.suffix.lower() == ".msr":
        return [root]
    return sorted(root.rglob("*.msr"))

def convert(paths: list[Path], output_dir: Path | None, combined: Path | None) -> list[Path]:
    measurements: list[Measurement] = []
    written: list[Path] = []
    for path in paths:
        measurement = parse_msr(path)
        measurements.append(measurement)
        dest_dir = output_dir if output_dir is not None else path.parent
        dest = dest_dir / f"{path.stem}.pdf"
        render_pdf(measurement, dest)
        written.append(dest)
        print(f"OK  {path} -> {dest}")
    if combined and measurements:
        combined.parent.mkdir(parents=True, exist_ok=True)
        with PdfPages(combined) as pdf:
            for measurement in measurements:
                fig, ax = plt.subplots(figsize=(11.69, 8.27))
                plot_measurement(measurement, ax)
                fig.tight_layout()
                pdf.savefig(fig)
                plt.close(fig)
        print(f"OK  combined -> {combined}")
        written.append(combined)
    return written

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Преобразует графики PHYWE measure (.msr) в PDF.")
    parser.add_argument("input", nargs="?", default=".", help="Папка или файл .msr")
    parser.add_argument("-o", "--output-dir", help="Куда сохранить PDF")
    parser.add_argument("--combined", nargs="?", const="all_graphs.pdf", help="Собрать все графики в один PDF")
    args = parser.parse_args(argv)
    root = Path(args.input).expanduser().resolve()
    if not root.exists():
        print(f"не найден путь: {root}", file=sys.stderr)
        return 1
    files = find_msr_files(root)
    if not files:
        print(f"в {root} нет файлов .msr", file=sys.stderr)
        return 1
    output_dir = Path(args.output_dir).expanduser().resolve() if args.output_dir else None
    combined = None
    if args.combined:
        combined_path = Path(args.combined)
        if output_dir is not None:
            combined = output_dir / combined_path.name
        elif combined_path.is_absolute() or combined_path.parent != Path("."):
            combined = combined_path.resolve()
        else:
            combined = (root if root.is_dir() else root.parent) / combined_path.name
    try:
        convert(files, output_dir, combined)
    except Exception as exc:
        print(f"ошибка: {exc}", file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
EOF_PY
done

# 3. Install dependencies
echo "Проверка зависимостей..."
for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! python3 -c "import $pkg" >/dev/null 2>&1; then
    echo "Установка $pkg..."
    python3 -m pip install "$pkg" || { echo "Ошибка при установке $pkg. Убедитесь, что у вас установлен pip." >&2; exit 1; }
  fi
done

# --- MAIN SCRIPT LOGIC ---

if [[ $# -lt 1 ]]; then
  usage
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
output_dir="${SCRIPT_DIR}/${folder_name}"
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
