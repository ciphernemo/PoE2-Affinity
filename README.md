# PoE2-Affinity

Sets CPU affinity and priority for the Steam-based PoE2 process.

![PoE2 Exalted Orb](https://raw.githubusercontent.com/ciphernemo/PoE2-Affinity/refs/heads/main/exalted_orb.png)

## Script's Process
1. Searches system for Steam and PoE2 via registry keys, the default install location, then recursive drive search. If multiple locations are found, prompt user for preferred location.
2. Determines available threads on system, ask how many threads to withhold from PoE2, then calculate affinity mask.
3. Find the Steam localconfig.vdf and libraryfolders.vdf files.
4. Create a single-line batch file in PoE2's folder that launches PoE2 with CPU affinity settings.
5. Read the localconfig.vdf in a PSObject and add launch options for PoE2.
6. Create a backup of Steam's localconfig.vdf file.
7. Saves changes to localconfig.vdf

## Notes
* Creates a log file in the same location and of the same name as this script.
* Requires Powershell 3+ (Windows 11, 10, 8, and Server 2025, 2022, 2019, 2016, 2012)
* Use System.IO.File.WriteAllLines instead of Out-File to ensure UTF-8 encoding. Steam will reject UTF-16 encoded files.
* Feel free to take and re-work this script, according to its license, for use with other Steam games.
* Inspiration and reworked code from Steam-GetOnTop by ChiefIntegrator: https://github.com/ChiefIntegrator/Steam-GetOnTop
* Compiled with PS2EXE-GUI [Invoke-PS2EXE] v0.5.0.30 by Ingo Karstein & Markus Scholtes: https://github.com/MScholtes/PS2EXE

## Instructions
Download the pre-compiled executable within the "poe2_affinity.zip" file. Extract it anywhere, and run it. The program will walk you through the rest.
