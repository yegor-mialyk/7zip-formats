# 7-Zip HA Format Plugin

This plugin lets 7-Zip open and extract HA (`.ha`) archives created with HA 0.999b.
It is extraction-only: creating or updating HA archives is not supported.

## Installation

### 7-Zip

1. Locate the 7-Zip installation folder, the one containing `7z.dll` (usually `C:\Program Files\7-Zip`).
2. Create a `Formats` subfolder there if it does not already exist.
3. Copy the plugin binary that matches your 7-Zip build into the `Formats` folder:
   - `Ha.x64.dll` for 64-bit 7-Zip
   - `Ha.x86.dll` for 32-bit 7-Zip

   For example, the 64-bit plugin should be at `C:\Program Files\7-Zip\Formats\Ha.x64.dll`.
4. Restart 7-Zip, then open an `.ha` archive to browse or extract its contents.

### Far Manager (ArcLite)

1. Locate the Far Manager installation folder, the one containing `Far.exe`.
2. Open `Plugins\ArcLite` in that folder.
3. Create a `Formats` subfolder there if it does not already exist.
4. Copy the plugin binary that matches your Far Manager build into the `Formats` folder:
   - `Ha.x64.format` for 64-bit Far Manager
   - `Ha.x86.format` for 32-bit Far Manager

   For example, the 64-bit plugin should be at `%FARHOME%\Plugins\ArcLite\Formats\Ha.x64.format`.
5. Restart Far Manager, then open an `.ha` archive to browse or extract its contents.

## Supported operations

- Open HA archives and list their contents.
- Test and extract files.
- Read-only access: archive creation and updates are not supported.
- Archives created with HA 0.999b are supported.

## Credits

The decompression source code was ported from the open source [HA](https://github.com/val-khokhlov/ha) archiver.

## License

Copyright (C) 1995-2026 Yegor Mialyk. All Rights Reserved.

Licensed under the [GPL](LICENSE) License.
