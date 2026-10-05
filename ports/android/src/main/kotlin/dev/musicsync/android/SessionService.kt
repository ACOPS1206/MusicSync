// SPDX-License-Identifier: MIT
package dev.musicsync.android
import android.app.*
import android.content.*
import android.content.pm.ServiceInfo
import android.media.projection.*
import android.os.*
import android.net.wifi.WifiManager
import dev.musicsync.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect

object Runtime {
    lateinit var platform:AndroidPlatform
    lateinit var session:Session
    fun initialize(context:Context){if(!::session.isInitialized){platform=AndroidPlatform(context.applicationContext);session=Session(platform)}}
}
class SessionService:Service() {
    private var multicast:WifiManager.MulticastLock?=null
    private var latencyLock:WifiManager.WifiLock?=null
    private var performanceLock:WifiManager.WifiLock?=null
    private var cpuLock:PowerManager.WakeLock?=null
    @Volatile private var destroyed=false
    private val scope=CoroutineScope(SupervisorJob()+Dispatchers.Default)
    override fun onCreate(){super.onCreate();Runtime.initialize(this)
        val wifi=applicationContext.getSystemService(WifiManager::class.java);multicast=wifi.createMulticastLock("MusicSync Bonjour").also{it.setReferenceCounted(false);it.acquire()}
        latencyLock=wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_LOW_LATENCY,"MusicSync LAN latency").also{it.setReferenceCounted(false)}
        @Suppress("DEPRECATION")
        val highPerf=wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF,"MusicSync background LAN")
        performanceLock=highPerf.also{it.setReferenceCounted(false)}
        cpuLock=getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"MusicSync:audio-session").also{it.setReferenceCounted(false)}
        scope.launch{Runtime.session.state.collect{state->
            val active=state.connected||state.streaming||state.hostActive||state.phase in listOf("Connecting","Reconnecting")
            synchronized(this@SessionService){
                if(active&&!destroyed){
                    if(latencyLock?.isHeld==false)latencyLock?.acquire()
                    if(performanceLock?.isHeld==false)performanceLock?.acquire()
                    if(cpuLock?.isHeld==false)cpuLock?.acquire(10*60*1000L)
                }else releaseSessionLocks()
            }
        }}
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("session","MusicSync audio",NotificationManager.IMPORTANCE_LOW))
    }
    override fun onStartCommand(intent:Intent?,flags:Int,startId:Int):Int {
        val pending=PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE)
        val notification=Notification.Builder(this,"session").setContentTitle("MusicSync").setContentText("LAN audio session · Open MusicSync for synchronization status").setSmallIcon(android.R.drawable.ic_media_play).setContentIntent(pending).setOngoing(true).build()
        val capture=intent?.hasExtra("projectionResult")==true
        startForeground(1,notification,if(capture)ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION else ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        if(capture){
            @Suppress("DEPRECATION") val data=intent!!.getParcelableExtra<Intent>("projectionData")
            if(data!=null){Runtime.platform.projection?.stop();val projection=requireNotNull(getSystemService(MediaProjectionManager::class.java).getMediaProjection(intent.getIntExtra("projectionResult",Activity.RESULT_CANCELED),data))
                projection.registerCallback(object:MediaProjection.Callback(){override fun onStop(){Runtime.session.stopStreaming();Runtime.platform.projection=null}},Handler(Looper.getMainLooper()))
                Runtime.platform.projection=projection;Runtime.session.streamCapture()
            }
        }
        return START_NOT_STICKY
    }
    override fun onBind(intent:Intent?):IBinder?=null
    private fun releaseSessionLocks(){
        if(latencyLock?.isHeld==true)latencyLock?.release()
        if(performanceLock?.isHeld==true)performanceLock?.release()
        if(cpuLock?.isHeld==true)cpuLock?.release()
    }
    override fun onDestroy(){destroyed=true;scope.cancel();synchronized(this){releaseSessionLocks()};Runtime.platform.projection?.stop();Runtime.platform.projection=null;Runtime.session.disconnect();Runtime.session.stopHost();multicast?.release();super.onDestroy()}
}
