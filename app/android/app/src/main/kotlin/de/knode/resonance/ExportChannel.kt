package de.knode.resonance

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Exporting downloads: copies a song file into the shared Music folder (Music/Resonance/<collection>), where file
 * managers, a PC over USB and other music apps see it. Needs no storage permission on Android 10+. The copy runs on a
 * background thread; songs already exported under the same name are skipped.
 */
object ExportChannel {
    private val main = Handler(Looper.getMainLooper())

    fun register(context: Context, messenger: BinaryMessenger) {
        MethodChannel(messenger, "resonance/export").setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                "save" -> {
                    val path = call.argument<String>("path")!!
                    val folder = call.argument<String>("folder")!!
                    val name = call.argument<String>("name")!!
                    val mime = call.argument<String>("mime")!!
                    val replace = call.argument<Boolean>("replace") ?: false
                    Thread {
                        try {
                            val saved = save(context, path, folder, name, mime, replace)
                            main.post { result.success(saved) }
                        } catch (e: Exception) {
                            main.post { result.error("export", e.message, null) }
                        }
                    }.start()
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Returns false when a file of that name is already there (with [replace], it is replaced instead). */
    private fun save(
        context: Context,
        path: String,
        folder: String,
        name: String,
        mime: String,
        replace: Boolean,
    ): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) error("Android 10 or newer needed")
        val resolver = context.contentResolver
        val relative = "${Environment.DIRECTORY_MUSIC}/Resonance/$folder/"
        val collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val existing = "${MediaStore.Audio.Media.RELATIVE_PATH} = ? AND ${MediaStore.Audio.Media.DISPLAY_NAME} = ?"
        if (replace) {
            resolver.delete(collection, existing, arrayOf(relative, name))
        } else {
            resolver.query(collection, arrayOf(MediaStore.Audio.Media._ID), existing, arrayOf(relative, name), null)
                ?.use { if (it.count > 0) return false }
        }
        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, name)
            put(MediaStore.Audio.Media.MIME_TYPE, mime)
            put(MediaStore.Audio.Media.RELATIVE_PATH, relative)
            put(MediaStore.Audio.Media.IS_MUSIC, true)
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: error("MediaStore refused the file")
        try {
            resolver.openOutputStream(uri)!!.use { out -> File(path).inputStream().use { it.copyTo(out) } }
            resolver.update(uri, ContentValues().apply { put(MediaStore.Audio.Media.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        return true
    }
}
