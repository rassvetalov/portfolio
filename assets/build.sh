#!/usr/bin/env bash
set -euo pipefail

# Build recruiter-friendly formats from Markdown using Docker.
# Requirements: Docker installed and running.
#
# Output:
# - CV_Dmitriy_Rassvetalov_EN.pdf
# - CV_Dmitriy_Rassvetalov_RU.pdf
# - CV_Dmitriy_Rassvetalov_EN.docx

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

IMAGE="pandoc/latex:latest"

PDF_FLAGS=(
  "--pdf-engine=xelatex"
  "-V" "fontsize=10pt"
  "-V" "geometry:margin=0.7in"
  "--include-in-header=pandoc-header.tex"
)

docker run --rm \
  -v "$PWD:/data" \
  --entrypoint sh \
  "$IMAGE" \
  -lc "export PATH=/opt/texlive/texdir/bin/x86_64-linuxmusl:\$PATH; apk add --no-cache fontconfig ttf-dejavu >/dev/null; pandoc CV_Dmitriy_Rassvetalov_EN.md -o CV_Dmitriy_Rassvetalov_EN.pdf ${PDF_FLAGS[*]} -V mainfont='DejaVu Sans'"

docker run --rm \
  -v "$PWD:/data" \
  --entrypoint sh \
  "$IMAGE" \
  -lc "export PATH=/opt/texlive/texdir/bin/x86_64-linuxmusl:\$PATH; apk add --no-cache fontconfig ttf-dejavu >/dev/null; pandoc CV_Dmitriy_Rassvetalov_RU.md -o CV_Dmitriy_Rassvetalov_RU.pdf ${PDF_FLAGS[*]} -V mainfont='DejaVu Sans'"

docker run --rm \
  -v "$PWD:/data" \
  "$IMAGE" \
  CV_Dmitriy_Rassvetalov_EN.md -o CV_Dmitriy_Rassvetalov_EN.docx

echo "Done:"
ls -la CV_Dmitriy_Rassvetalov_EN.pdf CV_Dmitriy_Rassvetalov_RU.pdf CV_Dmitriy_Rassvetalov_EN.docx

