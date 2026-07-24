import Foundation
import Network
import CryptoKit

/// TLS-PSK + WebSocket transport shared by the Mac server (NWListener) and the iOS client
/// (NWConnection). Home-LAN trust: only a peer with the 32-byte PSK completes the handshake.
public enum RemoteTransport {
    public static let bonjourType = "_slate-remote._tcp"

    /// Length of a pairing key, in bytes. `PairingPayload` rejects anything else, so the two
    /// must agree — hence one constant rather than a 32 in each place.
    public static let pskBytes = 32

    public static func newPSK() -> Data {
        Data(SymmetricKey(size: .init(bitCount: pskBytes * 8)).withUnsafeBytes(Array.init))
    }

    public static func parameters(psk: Data) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        let keyDD = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let idDD = Data("slate-remote".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyDD as __DispatchData, idDD as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: 0x00A8)!) // TLS_PSK_WITH_AES_128_GCM_SHA256
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)
        let params = NWParameters(tls: tls)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // Infrastructure Wi-Fi only. Peer-to-peer (AWDL) would resolve the Mac to an IPv6
        // link-local with a %zone, which can't be expressed as a `wss://` URL host — the
        // client would fail to connect. Home Wi-Fi doesn't need it.
        params.includePeerToPeer = false
        return params
    }
}
