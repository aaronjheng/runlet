import Foundation

extension TabState {
    // MARK: - Slow Log

    func fetchSlowLog() async {
        guard let client = activeSession, client.isConnected else { return }
        isLoadingSlowLog = true
        slowLogError = nil

        do {
            let result = try await client.send("SLOWLOG", "GET", "\(slowLogFetchCount)")
            if case .error(let message) = result {
                throw RedisError.commandError(message)
            }

            let entries = parseSlowLogEntries(result)
            await MainActor.run {
                slowLogEntries = entries
                isLoadingSlowLog = false
            }
        } catch {
            await MainActor.run {
                slowLogError = error.localizedDescription
                isLoadingSlowLog = false
            }
        }
    }

    func fetchSlowLogLen() async -> Int {
        guard let client = activeSession, client.isConnected else { return 0 }
        do {
            let result = try await client.send("SLOWLOG", "LEN")
            return result.intValue ?? 0
        } catch {
            return 0
        }
    }

    private func parseSlowLogEntries(_ value: RESPValue) -> [SlowLogEntry] {
        guard case .array(let entries) = value else { return [] }

        return entries.compactMap { entry -> SlowLogEntry? in
            guard let entry else { return nil }
            let fields = entry.arrayValues.compactMap { $0 }

            guard fields.count >= 6 else { return nil }

            let id = fields[0].intValue ?? 0
            let timestampInt = fields[1].intValue ?? 0
            let duration = fields[2].intValue ?? 0
            let commandArr = fields[3].arrayValues.compactMap { $0?.string }
            let clientIP = fields[4].string ?? ""
            let clientName = fields[5].string ?? ""

            return SlowLogEntry(
                id: id,
                timestamp: Date(timeIntervalSince1970: TimeInterval(timestampInt)),
                duration: duration,
                command: commandArr,
                clientIP: clientIP,
                clientName: clientName
            )
        }
        .sorted { $0.id > $1.id }
    }
}
