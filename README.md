# Shamela Library — KOReader plugin

Browse and search the official **المكتبة الشاملة** catalog on a KOReader device.
Selecting a book downloads its official text archive and converts its SQLite
page database into a regular Arabic EPUB, which KOReader can open immediately.

## Install

Copy the complete `shamela.koplugin` directory into KOReader's `plugins`
directory, restart KOReader, then open the search menu and select **Shamela
Library**.

## Notes

The first catalog visit downloads Shamela's master catalog and caches it under
KOReader's data directory. The plugin only downloads a book when you select it.
It uses the Shamela sync API. Before browsing, open **API key…** and enter
your own key; you can also change the endpoint through **API settings…**.

Shamela's API offers textual SQLite archives rather than EPUBs. This plugin
intentionally converts only the text pages; scans and PDF links supplied by
some records are not bundled into the generated EPUB.
