"""Split a PDF into one file per page — helper for macros\\SplitPages.ahk.

Usage:  python split_pdf.py <input.pdf> <output_dir>
Writes  <output_dir>\\page 001.pdf, page 002.pdf, ...
Prints the page count on success (exit 0); an error message on failure (exit 1).

Deliberately tiny and offline: pypdf only, no network, no other deps.
"""
import os
import sys


def main() -> int:
    try:
        from pypdf import PdfReader, PdfWriter
    except ImportError:
        print("NEEDS_PYPDF")          # the macro recognizes this and offers the install
        return 1
    if len(sys.argv) != 3:
        print("usage: split_pdf.py <input.pdf> <output_dir>")
        return 1
    src, outdir = sys.argv[1], sys.argv[2]
    try:
        reader = PdfReader(src)
        if reader.is_encrypted:
            # Scans are sometimes "encrypted" with an empty owner password.
            try:
                reader.decrypt("")
            except Exception:
                print("This PDF is password-protected — remove the password first.")
                return 1
        os.makedirs(outdir, exist_ok=True)
        n = len(reader.pages)
        for i, page in enumerate(reader.pages, 1):
            writer = PdfWriter()
            writer.add_page(page)
            with open(os.path.join(outdir, f"page {i:03d}.pdf"), "wb") as f:
                writer.write(f)
        print(n)
        return 0
    except Exception as e:  # corrupt file, locked file, disk full...
        print(f"Couldn't split that PDF: {e}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
