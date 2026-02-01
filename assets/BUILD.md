# Building PDF/DOCX (optional)

This repository keeps the source CV in Markdown:

- `CV_Dmitriy_Rassvetalov_EN.md`
- `CV_Dmitriy_Rassvetalov_RU.md`

If you want recruiter-friendly formats, generate PDF/DOCX locally.

## Using Pandoc

```bash
# from repo root
cd assets

# EN PDF (requires a LaTeX engine installed in your system)
pandoc CV_Dmitriy_Rassvetalov_EN.md -o CV_Dmitriy_Rassvetalov_EN.pdf

# RU PDF (Cyrillic): prefer xelatex + a Unicode font installed
pandoc CV_Dmitriy_Rassvetalov_RU.md -o CV_Dmitriy_Rassvetalov_RU.pdf --pdf-engine=xelatex -V mainfont="DejaVu Sans"

# DOCX
pandoc CV_Dmitriy_Rassvetalov_EN.md -o CV_Dmitriy_Rassvetalov_EN.docx
```

## Using Docker (recommended)

```bash
cd assets
chmod +x build.sh
./build.sh
```

> Note: GitHub Pages will display Markdown directly; PDF/DOCX are optional.

