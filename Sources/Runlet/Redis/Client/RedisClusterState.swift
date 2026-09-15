import Foundation
import Synchronization

// MARK: - Cluster Connection Pool / Slot Topology

/// Actor guarding the per-endpoint connection pool and the slot-owner map.
/// Concurrency-safe: one connection task per endpoint, generation-stamped so
/// a stale connect can never clobber newer state.
actor RedisClusterState {
    private final class PendingConnectionClientBox: Sendable {
        private let storedClient = Mutex<RedisClient?>(nil)

        func set(_ client: RedisClient) {
            storedClient.withLock {
                $0 = client
            }
        }

        func client() -> RedisClient? {
            storedClient.withLock { $0 }
        }

        func disconnect() {
            client()?.disconnect()
        }
    }

    private struct PendingConnection {
        let id: UUID
        let generation: Int
        let clientBox: PendingConnectionClientBox
        let task: Task<RedisClient, Error>
    }

    private var clients: [RedisEndpoint: RedisClient] = [:]
    private var connectionTasks: [RedisEndpoint: PendingConnection] = [:]
    private var slotOwners = [RedisEndpoint?](repeating: nil, count: RedisClusterHash.slotCount)
    private var primaries: [RedisEndpoint] = []
    private var slotRanges: [RedisClusterSlotRange] = []
    private var fallbackEndpoint: RedisEndpoint?
    private var generation = 0

    func client(
        for endpoint: RedisEndpoint,
        endpointResolver: (any RedisClusterEndpointResolver)?,
        makeClient: @Sendable @escaping (RedisEndpoint) -> RedisClient
    ) async throws -> RedisClient {
        if let client = clients[endpoint], client.isConnected {
            return client
        }

        if let pendingConnection = connectionTasks[endpoint] {
            return try await resolveConnectionTask(pendingConnection, endpoint: endpoint)
        }

        let clientBox = PendingConnectionClientBox()
        let task = Task { [endpointResolver, makeClient] in
            let clientEndpoint: RedisEndpoint
            if let endpointResolver {
                clientEndpoint = try await endpointResolver.clientEndpoint(for: endpoint)
            } else {
                clientEndpoint = endpoint
            }
            try Task.checkCancellation()
            let client = makeClient(clientEndpoint)
            clientBox.set(client)
            try await client.connect()
            return client
        }
        let pendingConnection = PendingConnection(
            id: UUID(),
            generation: generation,
            clientBox: clientBox,
            task: task
        )
        connectionTasks[endpoint] = pendingConnection

        return try await resolveConnectionTask(pendingConnection, endpoint: endpoint)
    }

    private func resolveConnectionTask(
        _ pendingConnection: PendingConnection,
        endpoint: RedisEndpoint
    ) async throws -> RedisClient {
        do {
            let client = try await pendingConnection.task.value
            guard pendingConnection.generation == generation else {
                clearConnectionTask(pendingConnection, endpoint: endpoint)
                client.disconnect()
                throw RedisError.notConnected
            }
            clients[endpoint] = client
            clearConnectionTask(pendingConnection, endpoint: endpoint)
            return client
        } catch {
            clearConnectionTask(pendingConnection, endpoint: endpoint)
            removeCachedClient(for: endpoint, matching: pendingConnection)
            pendingConnection.clientBox.disconnect()
            throw error
        }
    }

    private func removeCachedClient(for endpoint: RedisEndpoint, matching pendingConnection: PendingConnection) {
        guard let pendingClient = pendingConnection.clientBox.client(), let client = clients[endpoint] else { return }
        guard ObjectIdentifier(client) == ObjectIdentifier(pendingClient) else { return }
        clients[endpoint] = nil
    }

    private func clearConnectionTask(_ pendingConnection: PendingConnection, endpoint: RedisEndpoint) {
        guard let current = connectionTasks[endpoint],
            current.generation == pendingConnection.generation,
            current.id == pendingConnection.id
        else {
            return
        }
        connectionTasks[endpoint] = nil
    }

    func updateTopology(_ ranges: [RedisClusterSlotRange], defaultEndpoint: RedisEndpoint) {
        var owners = [RedisEndpoint?](repeating: nil, count: RedisClusterHash.slotCount)
        var primarySet: Set<RedisEndpoint> = []
        var nextPrimaries: [RedisEndpoint] = []

        for range in ranges {
            guard range.start >= 0, range.end < RedisClusterHash.slotCount, range.start <= range.end else {
                continue
            }
            for slot in range.start...range.end {
                owners[slot] = range.primary
            }
            if primarySet.insert(range.primary).inserted {
                nextPrimaries.append(range.primary)
            }
        }

        slotOwners = owners
        primaries = nextPrimaries.sorted { $0.address < $1.address }
        slotRanges = ranges
        fallbackEndpoint = defaultEndpoint
    }

    func owner(for slot: Int) -> RedisEndpoint? {
        guard slot >= 0, slot < slotOwners.count else { return nil }
        return slotOwners[slot]
    }

    func replaceOwner(slot: Int, with endpoint: RedisEndpoint) {
        guard slot >= 0, slot < slotOwners.count else { return }
        slotOwners[slot] = endpoint
        if !primaries.contains(endpoint) {
            primaries.append(endpoint)
            primaries.sort { $0.address < $1.address }
        }
    }

    func primaryEndpoints() -> [RedisEndpoint] {
        primaries
    }

    func nodeSummaries() -> [RedisClusterNodeSummary] {
        var slotRangesByEndpoint: [RedisEndpoint: [RedisClusterSlotRangeSummary]] = [:]
        var replicaOfByEndpoint: [RedisEndpoint: RedisEndpoint] = [:]
        var rolesByEndpoint: [RedisEndpoint: RedisClusterNodeRole] = [:]

        for range in slotRanges {
            let summary = RedisClusterSlotRangeSummary(start: range.start, end: range.end)
            slotRangesByEndpoint[range.primary, default: []].append(summary)
            rolesByEndpoint[range.primary] = .primary

            for replica in range.replicas {
                replicaOfByEndpoint[replica] = range.primary
                rolesByEndpoint[replica] = .replica
            }
        }

        return rolesByEndpoint.keys.sorted { left, right in
            let leftRole = rolesByEndpoint[left] ?? .replica
            let rightRole = rolesByEndpoint[right] ?? .replica
            if leftRole != rightRole {
                return leftRole == .primary
            }
            return left.address < right.address
        }.map { endpoint in
            RedisClusterNodeSummary(
                endpoint: endpoint,
                role: rolesByEndpoint[endpoint] ?? .replica,
                slotRanges: (slotRangesByEndpoint[endpoint] ?? []).sorted { $0.start < $1.start },
                replicaOf: replicaOfByEndpoint[endpoint]
            )
        }
    }

    func defaultEndpoint() -> RedisEndpoint? {
        fallbackEndpoint ?? primaries.first
    }

    func disconnectAll() {
        generation += 1

        let pendingConnections = Array(connectionTasks.values)
        let connectedClients = Array(clients.values)

        connectionTasks.removeAll()
        clients.removeAll()

        for pendingConnection in pendingConnections {
            pendingConnection.task.cancel()
            pendingConnection.clientBox.disconnect()
        }

        for client in connectedClients {
            client.disconnect()
        }

        slotOwners = [RedisEndpoint?](repeating: nil, count: RedisClusterHash.slotCount)
        primaries = []
        slotRanges = []
        fallbackEndpoint = nil
    }
}
