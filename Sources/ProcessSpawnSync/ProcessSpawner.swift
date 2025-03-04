//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import Atomics
import CProcessSpawnSync
import Foundation
import NIOConcurrencyHelpers

extension ps_error_s {
  private func makeDescription() -> String {
    """
    PSError(\
    kind: \(self.pse_kind.rawValue), \
    errno: \(self.pse_code), \
    file: \(String(cString: self.pse_file)), \
    line: \(self.pse_line)\
    \(
      self.pse_extra_info != 0 ? ", extra: \(self.pse_extra_info)" : ""
    )
    """
  }
}

#if compiler(>=6.0)
extension ps_error_s: @retroactive CustomStringConvertible {
  public var description: String {
    self.makeDescription()
  }
}
#else
extension ps_error_s: CustomStringConvertible {
  public var description: String {
    self.makeDescription()
  }
}
#endif

public struct PSProcessUnknownError: Error & CustomStringConvertible {
  var reason: String

  public var description: String {
    self.reason
  }
}

public final class PSProcess: Sendable {
  enum PipeOrFileHandle: Sendable {
    case pipe(Pipe)
    case fileHandle(FileHandle)

    init?(_ any: Any?) {
      if let pipe = any as? Pipe {
        self = .pipe(pipe)
      } else if let fileHandle = any as? FileHandle {
        self = .fileHandle(fileHandle)
      } else {
        return nil
      }
    }

    var fileHandleForReading: FileHandle {
      switch self {
      case .pipe(let pipe):
        return pipe.fileHandleForReading
      case .fileHandle(let fileHandle):
        return fileHandle
      }
    }

    var fileHandleForWriting: FileHandle {
      switch self {
      case .pipe(let pipe):
        return pipe.fileHandleForWriting
      case .fileHandle(let fileHandle):
        return fileHandle
      }
    }

    var underlyingAsAny: Any {
      switch self {
      case .pipe(let pipe):
        return pipe
      case .fileHandle(let fileHandle):
        return fileHandle
      }
    }
  }

  struct State: Sendable {
    var executableURL: URL? = nil
    var currentDirectoryURL: URL? = nil
    var arguments: [String]? = nil
    var environment: [String: String]? = nil
    private(set) var pidWhenRunning: pid_t? = nil
    var standardInput: PipeOrFileHandle? = nil
    var standardOutput: PipeOrFileHandle? = nil
    var standardError: PipeOrFileHandle? = nil
    var terminationHandler: (@Sendable (PSProcess) -> ())? = nil
    private(set) var procecesIdentifier: pid_t? = nil
    private(set) var terminationStatus: (Process.TerminationReason, CInt)? = nil

    mutating func setRunning(pid: pid_t, isRunningApproximation: ManagedAtomic<Bool>) {
      assert(self.pidWhenRunning == nil)
      self.pidWhenRunning = pid
      self.procecesIdentifier = pid
      isRunningApproximation.store(true, ordering: .relaxed)
    }

    mutating func setNotRunning(
      terminationStaus: (Process.TerminationReason, CInt),
      isRunningApproximation: ManagedAtomic<Bool>
    ) -> @Sendable (PSProcess) -> () {
      assert(self.pidWhenRunning != nil)
      isRunningApproximation.store(false, ordering: .relaxed)
      self.pidWhenRunning = nil
      self.terminationStatus = terminationStaus
      let terminationHandler = self.terminationHandler ?? { _ in }
      self.terminationHandler = nil
      return terminationHandler
    }
  }

  let state = NIOLockedValueBox(State())
  let isRunningApproximation = ManagedAtomic(false)

  public init() {}

  public func run() throws {
    let state = self.state.withLockedValue { $0 }

    guard let pathString = state.executableURL?.path.removingPercentEncoding else {
      throw PSProcessUnknownError(reason: "executableURL is nil")
    }
    let path = copyOwnedCTypedString(pathString)
    defer {
      path.deallocate()
    }

    var cwd: UnsafeMutablePointer<CChar>? = nil
    if let currentDirectoryPathString = state.currentDirectoryURL?.path.removingPercentEncoding {
      cwd = copyOwnedCTypedString(currentDirectoryPathString)
    }
    defer { cwd?.deallocate() }

    let args = copyOwnedCTypedStringArray([pathString] + (state.arguments ?? []))
    defer {
      var index = 0
      var arg = args[index]
      while arg != nil {
        arg!.deallocate()
        index += 1
        arg = args[index]
      }
    }
    let environmentDictionary = state.environment ?? ProcessInfo.processInfo.environment
    let envs = copyOwnedCTypedStringArray((environmentDictionary.map { k, v in "\(k)=\(v)" }))
    defer {
      var index = 0
      var env = envs[index]
      while env != nil {
        env!.deallocate()
        index += 1
        env = envs[index]
      }
    }

    let psSetup: [ps_fd_setup] = [
      ps_fd_setup(
        psfd_kind: PS_MAP_FD,
        psfd_parent_fd: state.standardInput?.fileHandleForReading.fileDescriptor ?? STDIN_FILENO
      ),
      ps_fd_setup(psfd_kind: PS_MAP_FD, psfd_parent_fd: state.standardOutput?.fileHandleForWriting.fileDescriptor ?? STDOUT_FILENO),
      ps_fd_setup(psfd_kind: PS_MAP_FD, psfd_parent_fd: state.standardError?.fileHandleForWriting.fileDescriptor ?? STDERR_FILENO),
    ]
    let (pid, error) = psSetup.withUnsafeBufferPointer { psSetupPtr -> (pid_t, ps_error) in
      var config = ps_process_configuration_s(
        psc_path: path,
        psc_argv: args,
        psc_env: envs,
        psc_cwd: cwd,
        psc_fd_setup_count: CInt(psSetupPtr.count),
        psc_fd_setup_instructions: psSetupPtr.baseAddress!,
        psc_new_session: false,
        psc_close_other_fds: true
      )
      var error = ps_error()
      let pid = ps_spawn_process(&config, &error)
      return (pid, error)
    }
    try! state.standardInput?.fileHandleForReading.close()
    guard pid > 0 else {
      switch (error.pse_kind, error.pse_code) {
      case (PS_ERROR_KIND_EXECVE, ENOENT), (PS_ERROR_KIND_EXECVE, ENOTDIR):
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
      default:
        throw PSProcessUnknownError(reason: "\(error)")
      }
    }
    self.state.withLockedValue { state in
      state.setRunning(pid: pid, isRunningApproximation: self.isRunningApproximation)
    }

    let q = DispatchQueue(label: "q")
    let source = DispatchSource.makeSignalSource(signal: SIGCHLD, queue: q)
    source.setEventHandler {
      if let terminationHandler = self.terminationHandlerFinishedRunning() {
        source.cancel()
        terminationHandler(self)
      }
    }
    source.setRegistrationHandler {
      if let terminationHandler = self.terminationHandlerFinishedRunning() {
        source.cancel()
        q.async {
          terminationHandler(self)
        }
      }
    }
    source.resume()
  }

  public func interrupt() {
    _ = kill(processIdentifier, SIGINT)
  }

  public func terminate() {
    _ = kill(processIdentifier, SIGTERM)
  }

  public var processIdentifier: pid_t {
    self.state.withLockedValue { state in
      state.procecesIdentifier!
    }
  }

  public var terminationReason: Process.TerminationReason {
    self.state.withLockedValue { state in
      state.terminationStatus!.0
    }
  }

  public var terminationStatus: CInt {
    self.state.withLockedValue { state in
      state.terminationStatus!.1
    }
  }

  public var isRunning: Bool {
    self.isRunningApproximation.load(ordering: .relaxed)
  }

  func terminationHandlerFinishedRunning() -> (@Sendable (PSProcess) -> ())? {
    self.state.withLockedValue { state -> (@Sendable (PSProcess) -> ())? in
      guard let pid = state.pidWhenRunning else {
        return nil
      }
      var status: CInt = -1
      while true {
        let err = waitpid(pid, &status, WNOHANG)
        if err == -1 {
          if errno == EINTR {
            continue
          } else {
            preconditionFailure("waitpid failed with \(errno)")
          }
        } else {
          var hasExited = false
          var isExitCode = false
          var code: CInt = 0
          ps_convert_exit_status(status, &hasExited, &isExitCode, &code)
          if hasExited {
            return state.setNotRunning(
              terminationStaus: (isExitCode ? .exit : .uncaughtSignal, code),
              isRunningApproximation: self.isRunningApproximation
            )
          } else {
            return nil
          }
        }
      }
    }
  }

  public var executableURL: URL? {
    get {
      self.state.withLockedValue { state in
        state.executableURL
      }
    }
    set {
      self.state.withLockedValue { state in
        state.executableURL = newValue
      }
    }
  }

  public var currentDirectoryURL: URL? {
    get {
      self.state.withLockedValue { state in
        state.currentDirectoryURL
      }
    }
    set {
      self.state.withLockedValue { state in
        state.currentDirectoryURL = newValue
      }
    }
  }

  public var launchPath: String? {
    get {
      self.state.withLockedValue { state in
        state.executableURL?.absoluteString
      }
    }
    set {
      self.state.withLockedValue { state in
        state.executableURL = newValue.map { URL(fileURLWithPath: $0) }
      }
    }
  }

  public var arguments: [String]? {
    get {
      self.state.withLockedValue { state in
        state.arguments
      }
    }
    set {
      self.state.withLockedValue { state in
        state.arguments = newValue
      }
    }
  }

  public var environment: [String: String]? {
    get {
      self.state.withLockedValue { state in
        state.environment
      }
    }
    set {
      self.state.withLockedValue { state in
        state.environment = newValue
      }
    }
  }

  public var standardOutput: Any? {
    get {
      self.state.withLockedValue { state in
        state.standardOutput?.underlyingAsAny
      }
    }
    set {
      self.state.withLockedValue { state in
        state.standardOutput = .init(newValue)
      }
    }
  }

  public var standardError: Any? {
    get {
      self.state.withLockedValue { state in
        state.standardError?.underlyingAsAny
      }
    }
    set {
      self.state.withLockedValue { state in
        state.standardError = .init(newValue)
      }
    }
  }

  public var standardInput: Any? {
    get {
      self.state.withLockedValue { state in
        state.standardInput?.underlyingAsAny
      }
    }
    set {
      self.state.withLockedValue { state in
        state.standardInput = .init(newValue)
      }
    }
  }

  public var terminationHandler: (@Sendable (PSProcess) -> ())? {
    get {
      self.state.withLockedValue { state in
        state.terminationHandler
      }
    }
    set {
      self.state.withLockedValue { state in
        state.terminationHandler = newValue
      }
    }
  }
}

func copyOwnedCTypedString(_ string: String) -> UnsafeMutablePointer<CChar> {
  let out = UnsafeMutableBufferPointer<CChar>.allocate(capacity: string.utf8.count + 1)
  _ = out.initialize(from: string.utf8.map { CChar(bitPattern: $0) })
  out[out.endIndex - 1] = 0

  return out.baseAddress!
}

func copyOwnedCTypedStringArray(_ array: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
  let out = UnsafeMutableBufferPointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: array.count + 1)
  for (index, string) in array.enumerated() {
    out[index] = copyOwnedCTypedString(string)
  }
  out[out.endIndex - 1] = nil

  return out.baseAddress!
}
