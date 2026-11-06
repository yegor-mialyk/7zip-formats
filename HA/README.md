# 7-Zip HA Format Plugin

This plugin adds support for opening and extracting HA (`.ha`) archives created with HA 0.999b in 7-Zip.
It is extraction-only: creating or updating HA archives is not supported.

## Installation

1. Locate the Far Manager installation folder, the folder containing `Far.exe`.
2. Open `Plugins\ArcLite` in that folder.
3. Create a `Formats` subfolder if it does not already exist.
4. Choose the plugin binary that matches your Far Manager installation:
   - `Ha.x64.format` for 64-bit Far Manager
   - `Ha.x86.format` for 32-bit Far Manager
5. Copy the chosen file into the `Formats` folder. For example, the 64-bit plugin should be at `%FARHOME%\Plugins\ArcLite\Formats\Ha.x64.format`.
6. Restart Far Manager, then open an `.ha` archive to browse or extract its contents.

## Supported operations

- Open HA archives and list their contents.
- Test and extract files.
- Read-only access; archive creation and updates are not supported.
- Supports archives created with HA 0.999b.

## License

Copyright (C) 1995-2026 Yegor Mialyk. All Rights Reserved.

Licensed under the [GPL](LICENSE) License.
