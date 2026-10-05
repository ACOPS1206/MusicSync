// SPDX-License-Identifier: MIT
// Copyright (c) 2026 ACOPS1206
package dev.musicsync.core

import org.bouncycastle.tls.*
import org.bouncycastle.tls.crypto.TlsCryptoParameters
import org.bouncycastle.tls.crypto.impl.jcajce.JcaTlsCryptoProvider
import org.bouncycastle.tls.crypto.impl.jcajce.JcaDefaultTlsCredentialedSigner
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder
import org.bouncycastle.jce.provider.BouncyCastleProvider
import java.net.Socket
import java.net.SocketException
import java.net.SocketTimeoutException
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import java.math.BigInteger
import java.security.*
import java.security.spec.*
import java.security.interfaces.ECPublicKey
import java.security.cert.X509Certificate
import java.security.cert.CertificateFactory
import java.util.*
import java.io.*
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

fun pairingKey(key:String)=listOf("client.","host.","pin.","endpoint.","policy.").any{key.startsWith(it)}
interface Store { fun clearPairings() {} ; fun get(key: String): String?; fun put(key: String, value: String?); fun id(role: String): String = get("id.$role") ?: UUID.randomUUID().toString().uppercase().also { put("id.$role",it) } }
/** Keep identities persistent, but scope authorization and pins to one app session. */
class SessionStore(private val persistent:Store):Store {
    private val temporary=MemoryStore()
    init { persistent.clearPairings() }
    override fun get(key:String)=if(pairingKey(key))temporary.get(key)else persistent.get(key)
    override fun put(key:String,value:String?){if(pairingKey(key))temporary.put(key,value)else persistent.put(key,value)}
}
class MemoryStore : Store {
    private val values = java.util.concurrent.ConcurrentHashMap<String,String>()
    override fun clearPairings(){values.keys.filter{pairingKey(it)}.forEach{values.remove(it)}}
    override fun get(key: String) = values[key]
    override fun put(key: String, value: String?) { if (value == null) values.remove(key) else values[key] = value }
}
object Pairing {
    fun secret(): String = Base64.getEncoder().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
    fun proof(secret: String, nonce: String, hostID: String, clientID: String, binding: String): String {
        val bytes = Base64.getDecoder().decode(secret); require(bytes.size == 32)
        val mac = Mac.getInstance("HmacSHA256"); mac.init(SecretKeySpec(bytes,"HmacSHA256"))
        return Base64.getEncoder().encodeToString(mac.doFinal("MusicSync-pair-v2\n$hostID\n$clientID\n$nonce\n$binding".toByteArray()))
    }
    fun verify(proof: String?, secret: String, nonce: String, hostID: String, clientID: String, binding: String): Boolean =
        proof != null && proof.length <= 64 && runCatching { MessageDigest.isEqual(Base64.getDecoder().decode(proof),Base64.getDecoder().decode(proof(secret,nonce,hostID,clientID,binding))) }.getOrDefault(false)
    fun code(bytes: ByteArray): String {
        val hash = MessageDigest.getInstance("SHA-256").digest(bytes)
        return BigInteger(1,hash.copyOfRange(0,8)).mod(BigInteger.valueOf(100_000_000)).toString().padStart(8,'0')
    }
    fun pin(cert: X509Certificate): String {
        val key = cert.publicKey as? ECPublicKey ?: error("Host must use a P-256 key")
        require(key.params.curve.field.fieldSize == 256)
        fun coordinate(n: BigInteger): ByteArray = n.toByteArray().takeLast(32).toByteArray().let { ByteArray(32-it.size)+it }
        return MessageDigest.getInstance("SHA-256").digest(byteArrayOf(4)+coordinate(key.w.affineX)+coordinate(key.w.affineY)).joinToString("") { "%02x".format(it) }
    }
}
class Identity(store: Store) {
    val key: PrivateKey
    val cert: X509Certificate
    init {
        val provider = BouncyCastleProvider()
        val savedKey = store.get("tls.private")
        val savedCert = store.get("tls.cert")
        if (savedKey != null && savedCert != null) {
            key = KeyFactory.getInstance("EC",provider).generatePrivate(PKCS8EncodedKeySpec(Base64.getDecoder().decode(savedKey)))
            cert = CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(Base64.getDecoder().decode(savedCert))) as X509Certificate
        } else {
            val gen = KeyPairGenerator.getInstance("EC",provider); gen.initialize(ECGenParameterSpec("secp256r1"),SecureRandom())
            val pair = gen.generateKeyPair(); key = pair.private
            val name = X500Name("CN=MusicSync Local Host")
            val builder = JcaX509v3CertificateBuilder(name,BigInteger(128,SecureRandom()),Date(System.currentTimeMillis()-60000),Date(System.currentTimeMillis()+365L*86400000),name,pair.public)
            cert = JcaX509CertificateConverter().setProvider(provider).getCertificate(builder.build(JcaContentSignerBuilder("SHA256withECDSA").setProvider(provider).build(key)))
            store.put("tls.private",Base64.getEncoder().encodeToString(key.encoded)); store.put("tls.cert",Base64.getEncoder().encodeToString(cert.encoded))
        }
    }
}
/** TLS 1.3 only. No session resumption, plaintext fallback or automatic pin replacement. */
class SecurePeer private constructor(val socket: Socket, private val protocol: TlsProtocol, val binding: String, val code: String, val pin: String?) : AutoCloseable {
    val id: String = UUID.randomUUID().toString().uppercase()
    private val closed = AtomicBoolean(false)
    private val outbox = SendBacklog()
    var onMessage: (Message)->Unit = {}
    var onClose: (String)->Unit = {}
    fun start() {
        thread("MusicSync TLS write") {
            while (!closed.get()) {
                val data = outbox.take()
                if(data.isEmpty())break
                protocol.outputStream.write(data); protocol.outputStream.flush()
            }
        }
        thread("MusicSync TLS read") { while (!closed.get()) onMessage(Wire.read(protocol.inputStream)) }
    }
    fun send(m: Message) {
        if (closed.get()) return
        val data = Wire.encode(m)
        if (!outbox.offer(data,m.kind=="audio")) end("Control send backlog exceeded; reconnecting")
    }
    private fun thread(name: String, action: ()->Unit) = kotlin.concurrent.thread(name=name,isDaemon=true) {
        try { action() } catch (e: Exception) { end(TransportDiagnostics.describe(e,name)) }
    }
    private fun end(reason: String) {
        if (closed.compareAndSet(false,true)) {
            runCatching { socket.close() }; outbox.close(); onClose(reason)
        }
    }
    override fun close() { end("Disconnected") }
    companion object {
        private fun crypto() = JcaTlsCryptoProvider().setProvider(BouncyCastleProvider()).create(SecureRandom())
        fun client(socket: Socket, expectedPin: String? = null): SecurePeer {
            socket.soTimeout = 15000; socket.tcpNoDelay = true
            val crypto = crypto(); var binding = byteArrayOf(); var pin: String? = null
            val client = object : DefaultTlsClient(crypto) {
                override fun getSupportedVersions() = arrayOf(ProtocolVersion.TLSv13)
                override fun getAuthentication(): TlsAuthentication = object : TlsAuthentication {
                    override fun notifyServerCertificate(serverCertificate: TlsServerCertificate) {
                        val raw = serverCertificate.certificate.getCertificateAt(0).encoded
                        val cert = CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(raw)) as X509Certificate
                        val actual = Pairing.pin(cert)
                        require(expectedPin == null || expectedPin == actual) { "Host key changed: forget pairing only after verifying the Host" }
                        pin = actual
                    }
                    override fun getClientCredentials(request: CertificateRequest): TlsCredentials? = null
                }
                override fun notifyHandshakeComplete() { super.notifyHandshakeComplete(); binding = context.exportKeyingMaterial("EXPORTER-MusicSync-pairing-v2",null,32) }
            }
            val protocol = TlsClientProtocol(socket.getInputStream(),socket.getOutputStream()); protocol.connect(client)
            require(binding.size == 32 && pin != null); socket.soTimeout = 0
            return SecurePeer(socket,protocol,Base64.getEncoder().encodeToString(binding),Pairing.code(binding),pin)
        }
        fun server(socket: Socket, identity: Identity): SecurePeer {
            socket.soTimeout = 15000; socket.tcpNoDelay = true
            val crypto = crypto(); var binding = byteArrayOf()
            val server = object : DefaultTlsServer(crypto) {
                override fun getSupportedVersions() = arrayOf(ProtocolVersion.TLSv13)
                override fun getCredentials(): TlsCredentials = getECDSASignerCredentials()
                override fun getECDSASignerCredentials(): TlsCredentialedSigner {
                    val chain = org.bouncycastle.tls.Certificate(byteArrayOf(),arrayOf(CertificateEntry(crypto.createCertificate(identity.cert.encoded),null)))
                    return JcaDefaultTlsCredentialedSigner(TlsCryptoParameters(context),crypto,identity.key,chain,SignatureAndHashAlgorithm(HashAlgorithm.sha256,SignatureAlgorithm.ecdsa))
                }
                override fun notifyHandshakeComplete() { super.notifyHandshakeComplete(); binding = context.exportKeyingMaterial("EXPORTER-MusicSync-pairing-v2",null,32) }
            }
            val protocol = TlsServerProtocol(socket.getInputStream(),socket.getOutputStream()); protocol.accept(server)
            require(binding.size == 32); socket.soTimeout = 0
            return SecurePeer(socket,protocol,Base64.getEncoder().encodeToString(binding),Pairing.code(binding),null)
        }
    }
}

/** Bounded TLS backlog: discard old audio before it becomes late; preserve control frames. */
internal class SendBacklog(private val audioBudget:Int=96*1024,private val hardBudget:Int=512*1024,private val capacity:Int=128) {
    private data class Entry(val bytes:ByteArray,val audio:Boolean)
    private val lock=ReentrantLock();private val ready=lock.newCondition()
    private val queue=ArrayDeque<Entry>();private var size=0;private var closed=false
    var discardedAudio=0;private set
    val queuedBytes get()=lock.withLock{size}
    private fun discardAudio():Boolean {
        val iterator=queue.iterator()
        while(iterator.hasNext()){val entry=iterator.next();if(entry.audio){iterator.remove();size-=entry.bytes.size;discardedAudio++;return true}}
        return false
    }
    fun offer(bytes:ByteArray,audio:Boolean):Boolean=lock.withLock{
        if(closed)return false
        val budget=if(audio)audioBudget else hardBudget
        while(size+bytes.size>budget||queue.size>=capacity){
            if(!discardAudio()){if(audio){discardedAudio++;return true}else return false}
        }
        queue.addLast(Entry(bytes,audio));size+=bytes.size;ready.signal();true
    }
    fun take():ByteArray=lock.withLock{
        while(queue.isEmpty()&&!closed)ready.await()
        val entry=queue.pollFirst()?:return ByteArray(0)
        size-=entry.bytes.size;entry.bytes
    }
    fun close()=lock.withLock{closed=true;queue.clear();size=0;ready.signalAll()}
}
object TransportDiagnostics {
    fun describe(error:Throwable,phase:String):String {
        var cause:Throwable?=error
        repeat(5){
            val found=cause
            if(found is SocketException||found is SocketTimeoutException){
                val detail=found!!.message?.replace('\n',' ')?.take(100)?:"no OS detail"
                return "$phase: ${found.javaClass.simpleName}: $detail"
            }
            cause=found?.cause
        }
        // Parser/TLS errors can contain credentials in their message. Never echo raw data.
        return "$phase: ${error.javaClass.simpleName}"
    }
}
