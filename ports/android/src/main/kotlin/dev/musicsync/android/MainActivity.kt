// SPDX-License-Identifier: MIT
package dev.musicsync.android
import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import dev.musicsync.ui.MusicSyncApp

class MainActivity:ComponentActivity() {
    private val file=registerForActivityResult(ActivityResultContracts.OpenDocument()){uri->if(uri!=null){runCatching{contentResolver.takePersistableUriPermission(uri,Intent.FLAG_GRANT_READ_URI_PERMISSION)};service();Runtime.session.streamFile(uri.toString())}}
    private val projection=registerForActivityResult(ActivityResultContracts.StartActivityForResult()){result->if(result.resultCode==Activity.RESULT_OK&&result.data!=null){ContextCompat.startForegroundService(this,Intent(this,SessionService::class.java).putExtra("projectionResult",result.resultCode).putExtra("projectionData",result.data))}}
    private val microphone=registerForActivityResult(ActivityResultContracts.RequestPermission()){granted->if(granted)projection.launch(getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())}
    private val notifications=registerForActivityResult(ActivityResultContracts.RequestPermission()){}
    private fun service(){if(Build.VERSION.SDK_INT>=33&&ContextCompat.checkSelfPermission(this,Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)notifications.launch(Manifest.permission.POST_NOTIFICATIONS);ContextCompat.startForegroundService(this,Intent(this,SessionService::class.java))}
    override fun onCreate(savedInstanceState:Bundle?){super.onCreate(savedInstanceState);Runtime.initialize(this)
        setContent{MusicSyncApp(Runtime.session,onFile={file.launch(arrayOf("audio/wav","audio/x-wav","audio/wave"))},onCapture={
            if(ContextCompat.checkSelfPermission(this,Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED)projection.launch(getSystemService(MediaProjectionManager::class.java).createScreenCaptureIntent())else microphone.launch(Manifest.permission.RECORD_AUDIO)
        },onBegin={service()},onEnd={stopService(Intent(this,SessionService::class.java))})}
    }
}
