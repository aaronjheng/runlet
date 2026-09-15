import Foundation
import NIO
import NIOCore
@preconcurrency import NIOSSH

/// Accepts all SSH server host keys without verification.
///
/// - Note: This is a known security limitation: the app is vulnerable to
///   man-in-the-middle attacks on SSH connections. A future improvement
///   should implement known-hosts verification (e.g. `~/.ssh/known_hosts`)
///   or at minimum cache the first-seen host key and warn on mismatch.
final class AcceptAllServerHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

struct SSHAuthDelegateBox: @unchecked Sendable {
    let value: NIOSSHClientUserAuthenticationDelegate
}

struct SSHServerAuthDelegateBox: @unchecked Sendable {
    let value: AcceptAllServerHostKeysDelegate
}

struct SSHHandlerBox: @unchecked Sendable {
    let value: NIOSSHHandler
}

final class HandshakeHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    typealias InboundOut = Any

    private let promise: EventLoopPromise<Void>
    private var completed = false

    init(promise: EventLoopPromise<Void>) {
        self.promise = promise
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if !completed, event is UserAuthSuccessEvent {
            completed = true
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            promise.fail(SSHTunnelError.tunnelClosed)
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !completed {
            completed = true
            promise.fail(error)
        }
        context.fireErrorCaught(error)
    }
}

final class DataForwarder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let target: Channel

    init(target: Channel) {
        self.target = target
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        target.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        target.close(promise: nil)
        context.fireChannelInactive()
    }
}

final class SSHWrapperHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)

        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else {
            context.fireErrorCaught(SSHTunnelError.handshakeFailed("Unexpected SSH channel data"))
            return
        }

        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = unwrapOutboundIn(data)
        let wrapped = SSHChannelData(type: .channel, data: .byteBuffer(data))
        context.write(wrapOutboundOut(wrapped), promise: promise)
    }
}

final class ErrorHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        AppLogger.error("channel error", category: "SSHTunnel", fields: ["error": "\(error)"])
        context.close(promise: nil)
    }
}
