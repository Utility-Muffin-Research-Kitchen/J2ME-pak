# Bundled locale

`C.utf8/` is glibc's C.utf8 locale. It ships because the MLP1 firmware carries
no locale data at all: `/usr/lib/locale` does not exist and `C.UTF-8` cannot be
selected either. A JVM started without a locale derives `sun.jnu.encoding`
from the C locale (`ANSI_X3.4-1968`), so every non-ASCII file name fails, both
for the ROM the core hands to the jar and for the per-game directories
FreeJ2ME creates from the MIDlet name.

The files are architecture-independent and were generated from glibc 2.35's
localedata with that release's own `localedef`:

```sh
localedef -c -i C -f UTF-8 C.utf8
```

glibc 2.38 (the MLP1's) reads this 2.35 build. Only `LC_CTYPE` matters in
practice, but the whole locale is kept so that `setlocale(LC_ALL, "")`
succeeds.

Licence: **LGPL-2.1-or-later**, as part of glibc. The corresponding source is
glibc's `localedata/` directory for the release the locale was generated from
(the `C` locale source, `i18n_ctype`, the UTF-8 charmap and the `localedef`
tool). No transliteration tables are used at runtime by this locale, so they
are not needed to regenerate it.
