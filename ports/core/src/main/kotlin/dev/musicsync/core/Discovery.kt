// SPDX-License-Identifier: MIT
package dev.musicsync.core
import javax.jmdns.*
import java.net.*

/** IPv4 LAN discovery, same Bonjour DNS-SD service as Apple apps. */
data class Nearby(val name: String, val address: String, val port: Int)
class Discovery(private val update: (List<Nearby>)->Unit, private val failure: (String)->Unit) : AutoCloseable {
    private val entries = java.util.concurrent.ConcurrentHashMap<String,Nearby>()
    @Volatile private var dns: JmDNS? = null
    @Volatile private var stopped = false
    private var advertised: ServiceInfo? = null
    fun start() = kotlin.concurrent.thread(name="MusicSync Bonjour",isDaemon=true) {
        try {
            val address = lanAddress() ?: error("No IPv4 LAN interface")
            val instance = JmDNS.create(address,"MusicSync-${address.hostAddress.replace('.','-')}")
            if (stopped) { instance.close(); return@thread }
            dns = instance
            instance.addServiceListener(TYPE,object : ServiceListener {
                override fun serviceAdded(event: ServiceEvent) { instance.requestServiceInfo(TYPE,event.name,true) }
                override fun serviceRemoved(event: ServiceEvent) { entries.remove(event.name); update(entries.values.sortedBy { it.name }) }
                override fun serviceResolved(event: ServiceEvent) {
                    val ip = event.info.inet4Addresses.firstOrNull() ?: return
                    if (event.info.port > 0) { entries[event.name] = Nearby(event.name,ip.hostAddress,event.info.port); update(entries.values.sortedBy { it.name }) }
                }
            })
        } catch (e: Exception) { failure(e.message ?: "Bonjour unavailable") }
    }
    @Synchronized fun advertise(name: String,port: Int) {
        val instance = dns ?: return
        advertised?.let { instance.unregisterService(it) }
        advertised = ServiceInfo.create(TYPE,name,port,0,0,mapOf("protocol" to "1", "pairing" to "2")).also { instance.registerService(it) }
    }
    @Synchronized fun unadvertise() { advertised?.let { dns?.unregisterService(it) }; advertised = null }
    val address get() = dns?.hostName
    override fun close() { stopped = true; kotlin.concurrent.thread(isDaemon=true) { runCatching { dns?.close() } }; dns = null }
    companion object {
        const val TYPE = "_musicsync._tcp.local."
        fun lanAddress():Inet4Address?=NetworkInterface.getNetworkInterfaces().toList().filter{it.isUp&&!it.isLoopback&&!it.isVirtual}.flatMap{it.inetAddresses.toList()}.filterIsInstance<Inet4Address>().firstOrNull{it.isSiteLocalAddress}
    }
}
