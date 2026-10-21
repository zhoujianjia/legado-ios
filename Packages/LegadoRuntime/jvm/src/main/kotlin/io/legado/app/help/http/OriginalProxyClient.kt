package io.legado.app.help.http

import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Response
import java.net.InetSocketAddress
import java.net.Proxy

/** Locked HttpHelper.getProxyClient behavior on the existing session client.
 * Derived clients share its dispatcher/pool and task call cancellation. No
 * process-wide client, proxy selector or Authenticator is installed.
 */
internal fun configureOriginalProxyClient(base: OkHttpClient, proxy: String?): OkHttpClient {
    if (proxy.isNullOrBlank()) return base
    val config = parseProxyConfig(proxy)
    return base.newBuilder().apply {
        if (config.protocol == ProxyProtocol.SOCKS5 && config.credentials != null) {
            proxy(Proxy.NO_PROXY)
            dns(socks5ProxyDns)
            socketFactory(Socks5SocketFactory(config.host, config.port, config.credentials))
        } else {
            proxy(Proxy(config.protocol.proxyType, InetSocketAddress(config.host, config.port)))
        }
        config.credentials?.takeIf { config.protocol == ProxyProtocol.HTTP }?.let { credentials ->
            proxyAuthenticator { _, response ->
                val alreadyAuthorized = response.request.header("Proxy-Authorization") != null
                if (!shouldRetryProxyAuthentication(response.code, alreadyAuthorized, proxyChallenges(response))) {
                    null
                } else {
                    response.request.newBuilder()
                        .header("Proxy-Authorization", Credentials.basic(credentials.username, credentials.password))
                        .build()
                }
            }
        }
    }.build()
}

private fun proxyChallenges(response: Response): Int {
    var count = 0
    var current: Response? = response
    while (current?.code == 407) {
        count++
        current = current.priorResponse
    }
    return count
}
