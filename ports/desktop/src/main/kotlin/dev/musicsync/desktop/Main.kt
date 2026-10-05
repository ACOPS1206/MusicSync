// SPDX-License-Identifier: MIT
package dev.musicsync.desktop
import androidx.compose.runtime.*
import androidx.compose.ui.window.*
import androidx.compose.ui.unit.dp
import dev.musicsync.core.Session
import dev.musicsync.ui.MusicSyncApp
import java.awt.FileDialog
import java.awt.Frame

fun main() = application {
    val session=remember{Session(DesktopPlatform())}
    DisposableEffect(Unit){onDispose{session.close()}}
    Window(onCloseRequest={session.close();exitApplication()},title="MusicSync",state=rememberWindowState(width=780.dp,height=900.dp)){
        MusicSyncApp(session,onFile={
            val chooser=FileDialog(null as Frame?,"MusicSync · PCM WAV",FileDialog.LOAD);chooser.setFilenameFilter{_,name->name.endsWith(".wav",true)};chooser.isVisible=true
            if(chooser.file!=null)session.streamFile(java.io.File(chooser.directory,chooser.file).absolutePath);chooser.dispose()
        },onCapture={session.streamCapture()})
    }
}
