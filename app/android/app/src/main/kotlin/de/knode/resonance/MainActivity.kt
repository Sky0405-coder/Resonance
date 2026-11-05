package de.knode.resonance

import android.Manifest
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// AudioServiceActivity keeps playback alive in the background (media notification, lock screen).
class MainActivity : AudioServiceActivity() {
    private var device: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        device = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "resonance/device").apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTv" -> result.success(packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK))
                    "isDesktop" -> result.success(desktopMode(resources.configuration))
                    "deviceName" -> result.success(deviceName())
                    else -> result.notImplemented()
                }
            }
        }
        RingtoneChannel.register(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        ExportChannel.register(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    // Switching DeX on or off while the app runs only changes the configuration (see configChanges).
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        device?.invokeMethod("desktopMode", desktopMode(newConfig))
    }

    /** The name the user gave the phone (Settings > About), else the model, e.g. "Galaxy S24 Ultra". */
    private fun deviceName(): String {
        val named = listOf(
            Settings.Global.getString(contentResolver, "device_name"),
            Settings.Secure.getString(contentResolver, "bluetooth_name"),
        ).firstOrNull { !it.isNullOrBlank() }
        if (named != null) return named
        val model = Build.MODEL.orEmpty()
        val maker = Build.MANUFACTURER.orEmpty().replaceFirstChar { it.uppercase() }
        return if (model.startsWith(maker, ignoreCase = true)) model else "$maker $model".trim()
    }

    /** Samsung DeX, Android's desktop mode or a Chromebook: a big screen with mouse and keyboard. */
    private fun desktopMode(config: Configuration): Boolean {
        try {
            // Samsung only, not in the SDK.
            val type = config.javaClass
            if (type.getField("SEM_DESKTOP_MODE_ENABLED").getInt(type) == type.getField("semDesktopModeEnabled").getInt(config)) {
                return true
            }
        } catch (_: Exception) {
        }
        return (config.uiMode and Configuration.UI_MODE_TYPE_MASK) == Configuration.UI_MODE_TYPE_DESK ||
            packageManager.hasSystemFeature("android.hardware.type.pc")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Android 13+: without this permission many devices hide the playback notification and with it the
        // lock screen / quick settings media controls.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }
}
