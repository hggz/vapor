import Foundation
#if canImport(WinSDK)
import WinSDK
#endif

extension Environment {    
    /// The process information of an environment. Wraps `ProcessInto.processInfo`.
    @dynamicMemberLookup public struct Process {
        /// The process information of the environment.
        private let _info: ProcessInfo
        
        /// Creates a new `Process` wrapper for process information.
        ///
        /// - parameter info: The process info that the wrapper accesses. Defaults to `ProcessInto.processInfo`.
        internal init(info: ProcessInfo = .processInfo) {
            self._info = info
        }
        
        /// Gets a variable's value from the process' environment, and converts it to generic type `T`.
        ///
        ///     Environment.process.DATABASE_PORT = 3306
        ///     Environment.process.DATABASE_PORT // 3306
        public subscript<T>(dynamicMember member: String) -> T? where T: LosslessStringConvertible {
            get {
                return self._info.environment[member].flatMap { T($0) }
            }

            nonmutating set (value) {
                if let raw = value?.description {
                    #if os(Windows)
                    _ = member.withCString(encodedAs: UTF16.self) { keyPtr in
                        raw.withCString(encodedAs: UTF16.self) { valPtr in
                            SetEnvironmentVariableW(keyPtr, valPtr)
                        }
                    }
                    #else
                    setenv(member, raw, 1)
                    #endif
                } else {
                    #if os(Windows)
                    _ = member.withCString(encodedAs: UTF16.self) { keyPtr in
                        SetEnvironmentVariableW(keyPtr, nil)
                    }
                    #else
                    unsetenv(member)
                    #endif
                }
            }
        }
        
        /// Gets a variable's value from the process' environment as a `String`.
        ///
        ///     Environment.process.DATABASE_USER = "root"
        ///     Environment.process.DATABASE_USER // "root"
        public subscript(dynamicMember member: String) -> String? {
            get {
                return self._info.environment[member]
            }

            nonmutating set (value) {
                if let raw = value {
                    #if os(Windows)
                    _ = member.withCString(encodedAs: UTF16.self) { keyPtr in
                        raw.withCString(encodedAs: UTF16.self) { valPtr in
                            SetEnvironmentVariableW(keyPtr, valPtr)
                        }
                    }
                    #else
                    setenv(member, raw, 1)
                    #endif
                } else {
                    #if os(Windows)
                    _ = member.withCString(encodedAs: UTF16.self) { keyPtr in
                        SetEnvironmentVariableW(keyPtr, nil)
                    }
                    #else
                    unsetenv(member)
                    #endif
                }
            }
        }
    }
}
