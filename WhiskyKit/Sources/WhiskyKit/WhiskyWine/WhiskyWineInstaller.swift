//
//  WhiskyWineInstaller.swift
//  WhiskyKit
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import SemanticVersion

public class WhiskyWineInstaller {
    /// The Whisky application folder
    public static let applicationFolder = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: Bundle.whiskyBundleIdentifier)

    /// The folder of all the libfrary files
    public static let libraryFolder = applicationFolder.appending(path: "Libraries")

    /// URL to the installed `wine` `bin` directory
    public static let binFolder: URL = libraryFolder.appending(path: "Wine").appending(path: "bin")

    public static func isWhiskyWineInstalled() -> Bool {
        return whiskyWineVersion() != nil
    }

    public static func install(from: URL) {
        do {
            if !FileManager.default.fileExists(atPath: applicationFolder.path) {
                try FileManager.default.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
            } else {
                // Recreate it
                try FileManager.default.removeItem(at: applicationFolder)
                try FileManager.default.createDirectory(at: applicationFolder, withIntermediateDirectories: true)
            }

            try Tar.untar(tarBall: from, toURL: applicationFolder)
            try FileManager.default.removeItem(at: from)

            // Handle Gcenx tarball structure:
            // Extracts to "Wine Staging.app/Contents/Resources/wine/{bin,lib,share}"
            // but we need "Libraries/Wine/{bin,lib,share}"
            let gcenxWineRoot = applicationFolder
                .appending(path: "Wine Staging.app")
                .appending(path: "Contents")
                .appending(path: "Resources")
                .appending(path: "wine")

            if FileManager.default.fileExists(atPath: gcenxWineRoot.path) {
                let wineDir = libraryFolder.appending(path: "Wine")
                try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: gcenxWineRoot, to: wineDir)

                // Clean up the extracted app bundle
                let gcenxAppBundle = applicationFolder.appending(path: "Wine Staging.app")
                try FileManager.default.removeItem(at: gcenxAppBundle)
            }

            // Write WhiskyWineVersion.plist so isWhiskyWineInstalled() returns true
            let versionPlist = libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")
            let versionInfo = WhiskyWineVersion(version: SemanticVersion(11, 2, 0))
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let data = try encoder.encode(versionInfo)
            try data.write(to: versionPlist)

            // Apply OpenGL patch to winemac.so
            applyOpenGLPatch()
        } catch {
            print("Failed to install WhiskyWine: \(error)")
        }
    }

    /// Patches winemac.so to enable OpenGL 3.2+ context creation for SDL3-based games.
    /// Changes byte at offset 0x329fb from 0x74 (JE) to 0xEB (JMP).
    private static func applyOpenGLPatch() {
        let winemacPath = libraryFolder
            .appending(path: "Wine")
            .appending(path: "lib")
            .appending(path: "wine")
            .appending(path: "x86_64-unix")
            .appending(path: "winemac.so")

        guard FileManager.default.fileExists(atPath: winemacPath.path) else {
            print("winemac.so not found, skipping OpenGL patch")
            return
        }

        do {
            let fileHandle = try FileHandle(forUpdating: winemacPath)
            defer { fileHandle.closeFile() }

            let patchOffset: UInt64 = 0x329fb
            fileHandle.seek(toFileOffset: patchOffset)

            guard let currentByte = fileHandle.readData(ofLength: 1).first else {
                print("Failed to read byte at patch offset")
                return
            }

            if currentByte == 0x74 {
                fileHandle.seek(toFileOffset: patchOffset)
                fileHandle.write(Data([0xEB]))
                print("OpenGL patch applied successfully")
            } else if currentByte == 0xEB {
                print("OpenGL patch already applied")
            } else {
                print("Unexpected byte 0x\(String(currentByte, radix: 16)) at patch offset, skipping patch")
            }
        } catch {
            print("Failed to apply OpenGL patch: \(error)")
        }
    }

    public static func uninstall() {
        do {
            try FileManager.default.removeItem(at: libraryFolder)
        } catch {
            print("Failed to uninstall WhiskyWine: \(error)")
        }
    }

    public static func shouldUpdateWhiskyWine() async -> (Bool, SemanticVersion) {
        let versionPlistURL = "https://data.getwhisky.app/Wine/WhiskyWineVersion.plist"
        let localVersion = whiskyWineVersion()

        var remoteVersion: SemanticVersion?

        if let remoteUrl = URL(string: versionPlistURL) {
            remoteVersion = await withCheckedContinuation { continuation in
                URLSession(configuration: .ephemeral).dataTask(with: URLRequest(url: remoteUrl)) { data, _, error in
                    do {
                        if error == nil, let data = data {
                            let decoder = PropertyListDecoder()
                            let remoteInfo = try decoder.decode(WhiskyWineVersion.self, from: data)
                            let remoteVersion = remoteInfo.version

                            continuation.resume(returning: remoteVersion)
                            return
                        }
                        if let error = error {
                            print(error)
                        }
                    } catch {
                        print(error)
                    }

                    continuation.resume(returning: nil)
                }.resume()
            }
        }

        if let localVersion = localVersion, let remoteVersion = remoteVersion {
            if localVersion < remoteVersion {
                return (true, remoteVersion)
            }
        }

        return (false, SemanticVersion(0, 0, 0))
    }

    public static func whiskyWineVersion() -> SemanticVersion? {
        do {
            let versionPlist = libraryFolder
                .appending(path: "WhiskyWineVersion")
                .appendingPathExtension("plist")

            let decoder = PropertyListDecoder()
            let data = try Data(contentsOf: versionPlist)
            let info = try decoder.decode(WhiskyWineVersion.self, from: data)
            return info.version
        } catch {
            print(error)
            return nil
        }
    }
}

struct WhiskyWineVersion: Codable {
    var version: SemanticVersion = SemanticVersion(1, 0, 0)
}
