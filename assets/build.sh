#!/usr/bin/env bash
set -euo pipefail

# Build recruiter-friendly formats from Markdown using Docker.
# Requirements: Docker installed and running.
#
# Output:
# - CV_Dmitriy_Rassvetalov_EN.pdf
# - CV_Dmitriy_Rassvetalov_EN.docx

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

IMAGE="pandoc/latex:latest"

docker run --rm \
  -v "$PWD:/data" \
  "$IMAGE" \
  CV_Dmitriy_Rassvetalov_EN.md -o CV_Dmitriy_Rassvetalov_EN.pdf

docker run --rm \
  -v "$PWD:/data" \
  "$IMAGE" \
  CV_Dmitriy_Rassvetalov_EN.md -o CV_Dmitriy_Rassvetalov_EN.docx

echo "Done:"
ls -la CV_Dmitriy_Rassvetalov_EN.pdf CV_Dmitriy_Rassvetalov_EN.docx

