//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2014 - 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import SwiftOptions

import func TSCBasic.lookupExecutablePath
import protocol TSCBasic.FileSystem
import struct TSCBasic.AbsolutePath

extension UEFIToolchain {
  public func addPlatformSpecificLinkerArgs(
    to commandLine: inout [Job.ArgTemplate],
    parsedOptions: inout ParsedOptions,
    linkerOutputType: LinkOutputType,
    inputs: [TypedVirtualPath],
    outputFile: VirtualPath,
    shouldUseInputFileList: Bool,
    lto: LTOKind?,
    sanitizers: Set<Sanitizer>,
    targetInfo: FrontendTargetInfo
  ) throws -> ResolvedTool {
    let targetTriple = targetInfo.target.triple

    switch linkerOutputType {
    case .dynamicLibrary:
      throw Error.dynamicLibrariesUnsupported(targetTriple.triple)

    case .staticLibrary:
      commandLine.appendFlag("crs")
      commandLine.appendPath(outputFile)
      commandLine.append(contentsOf: inputs.lazy.filter { $0.type != .autolink }.map { .path($0.file) })
      return try resolvedTool(.staticLinker(lto))

    case .executable:
      // Pass the UEFI target triple so clang sets up the right PE/COFF defaults.
      if !targetTriple.triple.isEmpty {
        commandLine.appendFlag("-target")
        commandLine.appendFlag(targetTriple.triple)
      }

      // Select the linker to use (defaults to lld-link via clang's UEFI driver).
      if let linkerArg = parsedOptions.getLastArgument(.useLd)?.asSingle {
        commandLine.appendFlag("-fuse-ld=\(linkerArg)")
      }

      // Resolve clang, respecting --tools-directory.
      var clangPath = try getToolPath(.clang)
      if let toolsDirArg = parsedOptions.getLastArgument(.toolsDirectory) {
        let toolsDir = try AbsolutePath(validating: toolsDirArg.asSingle)
        if let tool = lookupExecutablePath(filename: "clang", searchPaths: [toolsDir]) {
          clangPath = tool
        }
        commandLine.appendFlag("-B")
        commandLine.appendPath(toolsDir)
      }

      // UEFI subsystem: default to EFI Application; users can override via -Xlinker.
      commandLine.appendFlag(.Xlinker)
      commandLine.appendFlag("/subsystem:efi_application")

      // UEFI is freestanding — no startup files or standard libraries.
      commandLine.appendFlag("-nostartfiles")
      commandLine.appendFlag("-nostdlib")

      // Add runtime library search paths.
      let runtimePaths = try runtimeLibraryPaths(
        for: targetInfo,
        parsedOptions: &parsedOptions,
        sdkPath: targetInfo.sdkPath?.path,
        isShared: false
      )
      for path in runtimePaths {
        commandLine.appendFlag(.L)
        commandLine.appendPath(path)
      }

      // Link swiftrt.obj if present (provides Swift runtime entry glue).
      if !parsedOptions.hasArgument(.nostartfiles) {
        let swiftrtPath = VirtualPath.lookup(targetInfo.runtimeResourcePath.path)
          .appending(components: targetTriple.platformName() ?? "",
                     targetTriple.archName, "swiftrt.obj")
        if (try? fileSystem.exists(swiftrtPath)) == true {
          commandLine.appendPath(swiftrtPath)
        }
      }

      // Add input object files.
      let inputFiles: [Job.ArgTemplate] = inputs.compactMap { input in
        if input.type == .object { return .path(input.file) }
        if lto != nil && input.type == .llvmBitcode { return .path(input.file) }
        return nil
      }
      commandLine.append(contentsOf: inputFiles)

      // Link the static Swift stdlib via a .lnk response file if present.
      let runtimeResourcePath = VirtualPath.lookup(targetInfo.runtimeResourcePath.path)
      let linkFilePath: VirtualPath = runtimeResourcePath
        .appending(components: targetTriple.platformName() ?? "",
                   "static-executable-args.lnk")
      if (try? fileSystem.exists(linkFilePath)) == true {
        commandLine.append(.responseFilePath(linkFilePath))
      }

      if let lto = lto {
        switch lto {
        case .llvmFull:  commandLine.appendFlag("-flto=full")
        case .llvmThin:  commandLine.appendFlag("-flto=thin")
        }
      }

      try commandLine.appendLast(.v, from: &parsedOptions)

      try commandLine.appendAllExcept(
        includeList: [.linkerOption],
        excludeList: [.l],
        from: &parsedOptions
      )
      addLinkedLibArgs(to: &commandLine, parsedOptions: &parsedOptions)
      try addExtraClangLinkerArgs(to: &commandLine, parsedOptions: &parsedOptions)

      commandLine.appendFlag(.o)
      commandLine.appendPath(outputFile)

      return try resolvedTool(.clang, pathOverride: clangPath)
    }
  }
}
