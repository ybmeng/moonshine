<div align="center">

  # Whisky v2 (Fork) 🥃
  *Wine but a bit stronger — now with better debugging*

  Forked from [Whisky-App/Whisky](https://github.com/Whisky-App/Whisky) (archived May 2025)
</div>

This fork keeps Whisky alive and improves it for newer macOS versions and better developer experience.

## System Requirements
- CPU: Apple Silicon (M-series chips — M1/M2/M3/M4)
- OS: macOS Sonoma 14.0 or later (tested on macOS 26)
- Xcode 16+ (for building from source)

## Building from Source

```bash
git clone https://github.com/ybmeng/Whisky.git
cd Whisky
xcodebuild -scheme Whisky -configuration Debug -arch arm64 \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=""
```

The built app will be at `~/Library/Developer/Xcode/DerivedData/Whisky-*/Build/Products/Debug/Whisky.app`.

> **Note:** You may need to install SwiftLint first: `brew install swiftlint`

---

## Changelog (from upstream v2.3.5)

### v2.4.0-fork — Fix silent crash logging

**Problem:** When a Windows exe crashed under Wine, Whisky showed no output. The log file only contained `msync: up and running.` with zero error detail, making it impossible to diagnose failures.

**Root cause:** Whisky launched programs via `wine start /unix <path>`, which spawns a **detached** child process and returns immediately. The parent Wine process's stdout/stderr was captured, but the child (the actual game/app) ran independently. When the child crashed, its output went nowhere.

#### Changes

**`WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift`**

- **`runProgram()`** — Removed `start /unix` from Wine arguments. Programs are now launched directly via `wine <path>`, keeping the process attached so all output (including crash messages like `Unhandled page fault...`) is captured in the log file.
- **`runWineProcess()`** (public and private) — Added `directory` parameter so the working directory can be set to the exe's parent folder. Previously `wine start` handled this implicitly; now it's explicit.
- **`generateRunCommand()`** — Updated terminal command generation to `cd` into the exe directory and run directly, matching the new behavior.
- **`constructWineEnvironment()`** — Changed `WINEDEBUG` from `fixme-all` to `fixme-all,err+all,warn+module`. This explicitly enables error-level messages and module loading warnings (e.g., failed DLL loads), which are critical for diagnosing why a program won't start.

**`WhiskyKit/Sources/WhiskyKit/Extensions/Process+Extensions.swift`**

- **Termination handler** — Now reads and logs any remaining buffered output from both stdout and stderr pipes before closing the log file. Previously this data was silently discarded via bare `readToEnd()` calls.
- **`logTermination()`** — Now accepts a `fileHandle` parameter and writes termination details (exit code, termination reason) to the log file, not just the system logger. Crash signals are explicitly labeled as `"uncaught signal (crash)"`.

#### Result

Wine crash messages now appear in `~/Library/Logs/com.isaacmarovitz.Whisky/*.log`. Example of what you'll now see in the log for a crashing program:

```
wine: Unhandled page fault on read access to 0000000000000084 at address 0000000140D5CA75 (thread 0024)
0024:err:seh:start_debugger Couldn't start debugger L"winedbg --auto 32 164" (2)

Process Mewgenics.exe terminated: status=5, reason=exit
```

### v2.5.0-fork — Upgrade Wine from CrossOver 22.1.1 to Wine Staging 11.2

**Problem:** The bundled Wine (WhiskyWine 2.5.0, based on CrossOver 22.1.1 from 2023) lacked support for modern Windows APIs including WinRT `Windows.Gaming.Input`, causing games using SDL3 game controller input to crash with null pointer dereferences.

**Solution:** Upgraded to [Wine Staging 11.2](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.2) (Feb 7, 2026), which includes years of improvements in WinRT support, DirectX compatibility, and game-specific fixes.

#### Changes

**`WhiskyKit/Sources/WhiskyKit/Wine/Wine.swift`**

- **`wineBinary`** — Changed from `wine64` to `wine` (Wine 11.x unified the binary name).
- **`generateTerminalEnvironmentCommand()`** — Updated all aliases from `wine64` to `wine`.

**`Whisky/Utils/Winetricks.swift`**

- Updated `WINE=wine64` to `WINE=wine`.

**Wine binary installation** (manual step)

- Replaced `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/` with Wine Staging 11.2 from [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds).
- Updated `WhiskyWineVersion.plist` to version 11.2.0.
- New Wine includes `winedbg` (crash debugger was missing from old build).

### v2.6.0-fork — Fix OpenGL 3.2 context creation on macOS (binary patch)

**Problem:** Games using OpenGL 3.2+ Core Profile (e.g., SDL3-based games) failed with `"Could not create GL context: Invalid handle"`. Wine's macOS display driver (`winemac.so`) rejected any `wglCreateContextAttribsARB` call requesting OpenGL 3.2+ without the `WGL_CONTEXT_FORWARD_COMPATIBLE_BIT_ARB` flag, because macOS's CGL framework requires forward-compatible mode for 3.2+ contexts.

**Root cause:** In `winemac.so`'s `macdrv_context_create()`, the function checks if the forward-compatible flag is set when the requested major version is >= 3. If the flag is absent, it logs `"OS X only supports forward-compatible 3.2+ contexts"` and returns `NULL` with `ERROR_INVALID_OPERATION`. Most Windows programs (including SDL3's GL backend) request OpenGL 3.2 Core Profile without the forward-compatible flag, because on Windows this flag is optional.

**Diagnosis:** Enabled Wine's WGL trace (`WINEDEBUG="+wgl"`) which revealed:

```
macdrv_context_create   Attrib 0x2091: 3    (WGL_CONTEXT_MAJOR_VERSION_ARB = 3)
macdrv_context_create   Attrib 0x2092: 2    (WGL_CONTEXT_MINOR_VERSION_ARB = 2)
macdrv_context_create   Attrib 0x9126: 1    (WGL_CONTEXT_PROFILE_MASK_ARB = Core)
warn:wgl:macdrv_context_create OS X only supports forward-compatible 3.2+ contexts
warn:wgl:win32u_context_create Failed to create driver context
```

The context request was valid but missing the forward-compatible bit (0x0002 in `WGL_CONTEXT_FLAGS_ARB`).

#### Binary patch

**File:** `~/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine/lib/wine/x86_64-unix/winemac.so`

**Method:** Disassembled `winemac.so` (Mach-O x86_64) with `otool -tV` and located the conditional branch that guards the forward-compatible check:

```asm
; At virtual address 0x329f9 (file offset 0x329fb, __TEXT.__text section):
;
; %al contains the result of the forward-compatible flag check:
;   al == 0  →  forward-compat flag IS present (continue normally)
;   al != 0  →  forward-compat flag is MISSING (fall through to error)
;
000329f9: testb  %al, %al
000329fb: je     0x32a1d          ; <-- jump to normal path only if flag present
000329fd: testb  $0x4, ...        ; check debug channel enabled
00032a04: je     0x32e52          ; jump to SetLastError + return NULL
00032a0a: leaq   ..., %rdx       ; "macdrv_context_create"
00032a11: leaq   ..., %rcx       ; "OS X only supports forward-compatible..."
00032a18: jmp    0x32e46          ; print warning, then SetLastError + return NULL
00032a1d: ...                     ; normal context creation continues here
```

**Patch:** Changed 1 byte at file offset `0x329fb`:

| Offset | Before | After | Meaning |
|--------|--------|-------|---------|
| `0x329fb` | `74` (`je`) | `eb` (`jmp`) | Unconditional jump to normal path |

This converts the conditional `je 0x32a1d` (jump-if-equal, opcode `0x74`) into an unconditional `jmp 0x32a1d` (short jump, opcode `0xeb`). The relative offset (`0x20`) remains the same. The effect is that `macdrv_context_create` now always proceeds to create the CGL context, implicitly using forward-compatible mode (which is all macOS supports anyway), instead of rejecting the request.

**Backup:** Original file saved as `winemac.so.bak-fwdcompat`.

#### Result

SDL3 games that request OpenGL 3.2 Core Profile now successfully create a GL context on macOS. Combined with MoltenVK providing Vulkan support, this enables the full range of SDL3 GPU backends (OpenGL, Vulkan, D3D12) to function under Wine on Apple Silicon.

---

## About the Original Project

Whisky provides a clean and easy to use graphical wrapper for Wine built in native SwiftUI. You can make and manage bottles, install and run Windows apps and games, and unlock the full potential of your Mac with no technical knowledge required. Originally built on top of CrossOver 22.1.1 and Apple's Game Porting Toolkit; this fork now uses Wine Staging 11.2.

## Credits & Acknowledgments

Whisky is possible thanks to the magic of several projects:

- [msync](https://github.com/marzent/wine-msync) by marzent
- [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) by Gcenx and doitsujin
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) by KhronosGroup
- [Sparkle](https://github.com/sparkle-project/Sparkle) by sparkle-project
- [SemanticVersion](https://github.com/SwiftPackageIndex/SemanticVersion) by SwiftPackageIndex
- [swift-argument-parser](https://github.com/apple/swift-argument-parser) by Apple
- [SwiftTextTable](https://github.com/scottrhoyt/SwiftyTextTable) by scottrhoyt
- [CrossOver 22.1.1](https://www.codeweavers.com/crossover) by CodeWeavers and WineHQ
- D3DMetal by Apple

Special thanks to Gcenx, ohaiibuzzle, and Nat Brown for their support and contributions!
