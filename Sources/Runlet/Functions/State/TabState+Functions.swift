import Foundation

extension TabState {
    // MARK: - Redis Functions

    /// Redis 7.0+ is required for Functions.
    var supportsFunctions: Bool {
        guard let version = serverInfo["Server"]?["redis_version"] else { return false }
        let major = version.split(separator: ".").first.flatMap { Int($0) } ?? 0
        return major >= 7
    }

    /// `FUNCTION LIST WITHCODE`. In cluster mode, lists are fetched from every
    /// primary and merged by library name, recording which nodes hold each library.
    func fetchFunctionLibraries() async {
        guard let client = activeSession, client.isConnected else { return }
        if !serverInfo.isEmpty && !supportsFunctions {
            functionLibraries = []
            isLoadingFunctions = false
            return
        }

        isLoadingFunctions = true
        functionsError = nil

        do {
            if client.mode == .cluster {
                let nodes = try await client.clusterNodes()
                let primaries = nodes.filter { $0.role == .primary }.map(\.endpoint)
                var merged: [String: RedisFunctionLibrary] = [:]
                for endpoint in primaries {
                    let result = try await client.send(
                        ["FUNCTION", "LIST", "WITHCODE"], to: endpoint
                    )
                    try throwIfRedisError(result)
                    for lib in parseFunctionLibraries(result, node: endpoint) {
                        if var existing = merged[lib.name] {
                            existing.nodes = (existing.nodes ?? []) + (lib.nodes ?? [])
                            merged[lib.name] = existing
                        } else {
                            merged[lib.name] = lib
                        }
                    }
                }
                functionLibraries = merged.values.sorted { $0.name < $1.name }
            } else {
                let result = try await client.send("FUNCTION", "LIST", "WITHCODE")
                try throwIfRedisError(result)
                functionLibraries = parseFunctionLibraries(result, node: nil)
            }
        } catch {
            functionsError = error.localizedDescription
        }

        isLoadingFunctions = false
    }

    /// `FUNCTION LOAD [REPLACE] <code>`. Sent to every primary in cluster mode.
    func loadFunctionLibrary(code: String, replace: Bool) async throws {
        var args = ["FUNCTION", "LOAD"]
        if replace { args.append("REPLACE") }
        args.append(code)
        do {
            try await sendToAllPrimaries(args)
            AppLogger.info(
                "function load ok replace=\(replace) bytes=\(code.utf8.count)",
                category: "Functions"
            )
            await fetchFunctionLibraries()
        } catch {
            AppLogger.error("function load failed replace=\(replace) error=\(error)", category: "Functions")
            throw error
        }
    }

    /// `FUNCTION DELETE <name>`. Sent to every primary in cluster mode.
    func deleteFunctionLibrary(name: String) async throws {
        do {
            try await sendToAllPrimaries(["FUNCTION", "DELETE", name])
            AppLogger.info("function delete ok library=\(name)", category: "Functions")
            if selectedFunctionLibrary?.name == name {
                selectedFunctionLibrary = nil
            }
            await fetchFunctionLibraries()
        } catch {
            AppLogger.error("function delete failed library=\(name) error=\(error)", category: "Functions")
            throw error
        }
    }

    // MARK: - Cluster helpers

    /// Sends a command to every primary node (cluster) or directly (standalone).
    /// In cluster mode the first encountered error is thrown after attempting
    /// all nodes, so partial failures are not silently swallowed from the UI.
    private func sendToAllPrimaries(_ args: [String]) async throws {
        guard let client = activeSession else { return }
        if client.mode == .cluster {
            let nodes = try await client.clusterNodes()
            let primaries = nodes.filter { $0.role == .primary }.map(\.endpoint)
            var firstError: Error?
            for endpoint in primaries {
                do {
                    let result = try await client.send(args, to: endpoint)
                    try throwIfRedisError(result)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
        } else {
            let result = try await client.send(args)
            try throwIfRedisError(result)
        }
    }

    // MARK: - Parsing

    /// Parses `FUNCTION LIST WITHCODE` output, compatible with both RESP2
    /// (array of key/value pairs) and RESP3 (array of maps).
    private func parseFunctionLibraries(_ value: RESPValue, node: RedisEndpoint?) -> [RedisFunctionLibrary] {
        value.arrayValues.compactMap { libValue -> RedisFunctionLibrary? in
            guard let libValue else { return nil }
            let pairs = libValue.keyValuePairs
            guard let name = functionFieldValue(in: pairs, key: "library_name")?.string else { return nil }
            let engine = functionFieldValue(in: pairs, key: "engine")?.string ?? "LUA"
            let code = functionFieldValue(in: pairs, key: "library_code")?.string ?? ""
            let functions = parseFunctions(functionFieldValue(in: pairs, key: "functions"))
            return RedisFunctionLibrary(
                name: name,
                engine: engine,
                functions: functions,
                code: code,
                nodes: node.map { [$0] }
            )
        }
    }

    private func parseFunctions(_ value: RESPValue?) -> [RedisFunction] {
        guard let value else { return [] }
        return value.arrayValues.compactMap { fnValue -> RedisFunction? in
            guard let fnValue else { return nil }
            let pairs = fnValue.keyValuePairs
            guard let name = functionFieldValue(in: pairs, key: "name")?.string else { return nil }
            let description = functionFieldValue(in: pairs, key: "description")?.string
            let flagsValue = functionFieldValue(in: pairs, key: "flags")
            let flags = flagsValue?.arrayValues.compactMap { $0?.string } ?? []
            return RedisFunction(name: name, description: description, flags: flags)
        }
    }

    /// Looks up a field value by key (case-insensitive) in RESP key/value pairs.
    private func functionFieldValue(
        in pairs: [(key: RESPValue, value: RESPValue)],
        key: String
    ) -> RESPValue? {
        pairs.first { $0.key.string?.lowercased() == key.lowercased() }?.value
    }

    // MARK: - Dry Run

    /// `FUNCTION DRYRUN <code>`. In cluster mode every primary is checked; the
    /// first error reported by any node is returned. Returns `nil` on success.
    func dryRunFunction(code: String) async -> String? {
        guard let client = activeSession, client.isConnected else {
            return "Not connected"
        }
        do {
            if client.mode == .cluster {
                let nodes = try await client.clusterNodes()
                let primaries = nodes.filter { $0.role == .primary }.map(\.endpoint)
                for endpoint in primaries {
                    let result = try await client.send(
                        ["FUNCTION", "DRYRUN", code], to: endpoint
                    )
                    if case .error(let message) = result {
                        AppLogger.warn("function dryrun failed endpoint=\(endpoint.address) error=\(message)", category: "Functions")
                        return message
                    }
                }
            } else {
                let result = try await client.send("FUNCTION", "DRYRUN", code)
                if case .error(let message) = result {
                    AppLogger.warn("function dryrun failed error=\(message)", category: "Functions")
                    return message
                }
            }
            AppLogger.info("function dryrun ok bytes=\(code.utf8.count)", category: "Functions")
            return nil
        } catch {
            AppLogger.warn("function dryrun failed error=\(error)", category: "Functions")
            return error.localizedDescription
        }
    }

    // MARK: - Function Calls (FCALL / FCALL_RO)

    /// Invokes a function. Routing is key-based, so the cluster client handles
    /// it automatically (no per-node fan-out needed).
    func callFunction(name: String, keys: [String], args: [String], isReadOnly: Bool) async {
        guard let client = activeSession, client.isConnected else { return }
        isCallingFunction = true
        defer { isCallingFunction = false }

        var command = [isReadOnly ? "FCALL_RO" : "FCALL", name, "\(keys.count)"]
        command.append(contentsOf: keys)
        command.append(contentsOf: args)

        let response: RESPValue
        let errorMessage: String?
        do {
            response = try await client.send(command)
            if case .error(let message) = response {
                errorMessage = message
                AppLogger.error(
                    "fcall failed name=\(name) keys=\(keys.count) args=\(args.count) error=\(message)",
                    category: "Functions"
                )
            } else {
                errorMessage = nil
                AppLogger.info(
                    "fcall ok name=\(name) keys=\(keys.count) args=\(args.count)",
                    category: "Functions"
                )
            }
        } catch {
            response = .null
            errorMessage = error.localizedDescription
            AppLogger.error(
                "fcall failed name=\(name) keys=\(keys.count) args=\(args.count) error=\(error)",
                category: "Functions"
            )
        }

        let result = RedisFunctionCallResult(
            functionName: name,
            keys: keys,
            args: args,
            isReadOnly: isReadOnly,
            response: response,
            error: errorMessage,
            timestamp: Date()
        )
        functionCallHistory.insert(result, at: 0)
    }

}
