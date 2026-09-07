# Shamela Library — KOReader plugin

Browse and search the official **المكتبة الشاملة** catalog on a KOReader device.
Selecting a book reads its public, web-reader pages and converts them into a
regular Arabic EPUB, which KOReader can open immediately. Categories, title
search, and EPUB downloads all work without a Shamela API key, including on a
fresh installation.

## Install

Download [shamela.koplugin.zip](https://github.com/mohammed4bs/shamela.koplugin/releases/latest/download/shamela.koplugin.zip)
and extract it. Copy the included `shamela.koplugin` directory into KOReader's
`plugins` directory, restart KOReader, then open the search menu and select
**Shamela Library**.

Use the release download above for installation. GitHub's **Code → Download ZIP**
is a source archive and adds `-main` to the folder name; if you use that archive,
rename the extracted folder to `shamela.koplugin` before installing.

## Notes

An internet connection is required for browsing, title search, and downloads.
Categories and their book listings are read from the public website; title
search uses the website's public title-search service. For broad searches,
use a more specific title if the website does not return your book.

Upgrading from v0.1.0: replace the installed plugin folder with the new release
and restart KOReader. No API setup or cached catalog is needed. Previous API
settings and catalog files are no longer used.

Shamela's API offers textual SQLite archives rather than EPUBs. This plugin
intentionally converts only the text pages; scans and PDF links supplied by
some records are not bundled into the generated EPUB.
