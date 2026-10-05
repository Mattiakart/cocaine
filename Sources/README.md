New features live in their own files here (compiled together with main.swift by build.sh).
Files other than main.swift can't have top-level statements; hook in from main.swift.
Strings: add them to Localization/<lang>.lproj/<Feature>.strings (tables listed in Language.extraTables), not Localizable.strings.
