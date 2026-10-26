package de.knode.resonance

import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.provider.Settings
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Ringtones from songs: saves a cut into the shared Ringtones/Notifications/Alarms folder (where the system's sound
 * pickers look) and, with the "modify system settings" permission, makes it the default sound.
 */
object RingtoneChannel {
    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "resonance/ringtone").setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // MediaStore's RELATIVE_PATH (writing to shared folders without storage permission) needs 10+.
                    "supported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    "canWriteSettings" -> result.success(Settings.System.canWrite(context))
                    "openWriteSettings" -> {
                        context.startActivity(
                            Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:${context.packageName}"))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(null)
                    }
                    "openSoundSettings" -> {
                        context.startActivity(
                            Intent(Settings.ACTION_SOUND_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                        )
                        result.success(null)
                    }
                    "save" -> result.success(
                        save(
                            context,
                            call.argument<String>("path")!!,
                            call.argument<String>("title")!!,
                            call.argument<String>("artist") ?: "",
                            call.argument<String>("type")!!,
                        ).toString(),
                    )
                    "setDefault" -> {
                        RingtoneManager.setActualDefaultRingtoneUri(
                            context,
                            ringtoneType(call.argument<String>("type")!!),
                            Uri.parse(call.argument<String>("uri")!!),
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("ringtone", e.message, null)
            }
        }
    }

    private fun ringtoneType(type: String) = when (type) {
        "notification" -> RingtoneManager.TYPE_NOTIFICATION
        "alarm" -> RingtoneManager.TYPE_ALARM
        else -> RingtoneManager.TYPE_RINGTONE
    }

    private fun save(context: Context, path: String, title: String, artist: String, type: String): Uri {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) error("Android 10 or newer needed")
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, "$title.mp3")
            put(MediaStore.Audio.Media.TITLE, title)
            put(MediaStore.Audio.Media.ARTIST, artist)
            put(MediaStore.Audio.Media.MIME_TYPE, "audio/mpeg")
            put(
                MediaStore.Audio.Media.RELATIVE_PATH,
                when (type) {
                    "notification" -> Environment.DIRECTORY_NOTIFICATIONS
                    "alarm" -> Environment.DIRECTORY_ALARMS
                    else -> Environment.DIRECTORY_RINGTONES
                },
            )
            put(MediaStore.Audio.Media.IS_RINGTONE, type == "ringtone")
            put(MediaStore.Audio.Media.IS_NOTIFICATION, type == "notification")
            put(MediaStore.Audio.Media.IS_ALARM, type == "alarm")
            put(MediaStore.Audio.Media.IS_MUSIC, false)
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, values)
            ?: error("MediaStore refused the file")
        try {
            resolver.openOutputStream(uri)!!.use { out -> File(path).inputStream().use { it.copyTo(out) } }
            resolver.update(uri, ContentValues().apply { put(MediaStore.Audio.Media.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return uri
    }
}
