# Shamela Library — KOReader plugin

Browse and search the official **المكتبة الشاملة** catalog on a KOReader device.
Selecting a book reads its public, web-reader pages and converts them into a
regular Arabic EPUB, which KOReader can open immediately. EPUB downloads do
not require a Shamela API key.

## Install

Copy the complete `shamela.koplugin` directory into KOReader's `plugins`
directory, restart KOReader, then open the search menu and select **Shamela
Library**.

## Notes

The first catalog visit downloads Shamela's master catalog and caches it under
KOReader's data directory. The plugin only downloads a book when you select it.
The catalog cache may use Shamela's sync API, but EPUB generation uses the
public `shamela.ws` reader endpoint and does not need a key.

Shamela's API offers textual SQLite archives rather than EPUBs. This plugin
intentionally converts only the text pages; scans and PDF links supplied by
some records are not bundled into the generated EPUB.
