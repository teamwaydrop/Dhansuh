package com.waydrop.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ApplicationInfo
import android.content.res.Configuration
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Bundle
import android.util.Rational
import android.webkit.WebView
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val CHANNEL = "com.waydrop.app/pip"
    private var isPipEnabled = false
    private var pipChannel: MethodChannel? = null

    private val UPI_CHANNEL = "com.waydrop.app/upi_apps"
    private var upiChannel: MethodChannel? = null

    private val ACTION_RECENTER = "com.waydrop.app.PIP_RECENTER"
    private val ACTION_ZOOM_IN = "com.waydrop.app.PIP_ZOOM_IN"
    private val ACTION_ZOOM_OUT = "com.waydrop.app.PIP_ZOOM_OUT"
    private var pipReceiver: BroadcastReceiver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Register receiver for PiP actions
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            pipReceiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent == null) return
                    when (intent.action) {
                        ACTION_RECENTER -> pipChannel?.invokeMethod("pipRecenter", null)
                        ACTION_ZOOM_IN -> pipChannel?.invokeMethod("pipZoomIn", null)
                        ACTION_ZOOM_OUT -> pipChannel?.invokeMethod("pipZoomOut", null)
                    }
                }
            }
            val filter = IntentFilter().apply {
                addAction(ACTION_RECENTER)
                addAction(ACTION_ZOOM_IN)
                addAction(ACTION_ZOOM_OUT)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(pipReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(pipReceiver, filter)
            }
        }

        // Create high importance notification channel for FCM push notifications
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channelId = "high_importance_channel"
            val channelName = "High Importance Notifications"
            val channelDescription = "Used for critical order updates, chat messages, and alerts."
            val importance = NotificationManager.IMPORTANCE_HIGH
            val channel = NotificationChannel(channelId, channelName, importance).apply {
                description = channelDescription
                enableLights(true)
                enableVibration(true)
            }
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager?.createNotificationChannel(channel)

            // Create custom sound channel for order requests
            val orderChannelId = "order_alerts_v2"
            val orderChannelName = "Order Alerts"
            val orderChannelDescription = "Alerts for nearby orders"
            val soundUri = android.net.Uri.parse("android.resource://" + packageName + "/raw/order_nearby_sound")
            val audioAttributes = android.media.AudioAttributes.Builder()
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION)
                .build()
            val orderChannel = NotificationChannel(orderChannelId, orderChannelName, importance).apply {
                description = orderChannelDescription
                enableLights(true)
                enableVibration(true)
                setSound(soundUri, audioAttributes)
            }
            notificationManager?.createNotificationChannel(orderChannel)
        }

        // Only enable WebView debugging in debug/test builds for production security
        if (0 != (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE)) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        pipChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "isPipSupported" -> {
                    result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                }
                "setPipEnabled" -> {
                    isPipEnabled = call.argument<Boolean>("enabled") ?: false
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        try {
                            val builder = PictureInPictureParams.Builder()
                            builder.setAspectRatio(Rational(3, 4))
                            builder.setActions(getPipActions())
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                                builder.setAutoEnterEnabled(isPipEnabled)
                            }
                            setPictureInPictureParams(builder.build())
                        } catch (e: Exception) {
                            // Ignored or logged
                        }
                    }
                    result.success(null)
                }
                "enterPipMode" -> {
                    val entered = triggerEnterPip()
                    result.success(entered)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        // Used only to detect/open specific well-known UPI apps by package name (WayDrop never
        // builds a upi://pay intent -- see UpiAppLauncher on the Dart side). getLaunchIntentForPackage
        // is the same lookup PackageManager itself uses to resolve an app's home-screen icon tap, and
        // -- unlike PackageManager's other resolveActivity overload with the MATCH_DEFAULT_ONLY
        // flag -- it does not require the target activity to declare category.DEFAULT, so it
        // correctly finds LAUNCHER-only activities.
        upiChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPI_CHANNEL)
        upiChannel?.setMethodCallHandler { call, result ->
            val packageName = call.argument<String>("package")
            if (packageName.isNullOrEmpty()) {
                result.success(false)
                return@setMethodCallHandler
            }
            when (call.method) {
                "isAppInstalled" -> {
                    result.success(packageManager.getLaunchIntentForPackage(packageName) != null)
                }
                "openApp" -> {
                    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                    if (launchIntent != null) {
                        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        startActivity(launchIntent)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (isPipEnabled && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            triggerEnterPip()
        }
    }

    private fun getPipActions(): List<RemoteAction> {
        val actions = ArrayList<RemoteAction>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            // Recenter Action
            val recenterIntent = PendingIntent.getBroadcast(this, 1, Intent(ACTION_RECENTER), flags)
            val recenterIcon = Icon.createWithResource(this, android.R.drawable.ic_menu_mylocation)
            actions.add(RemoteAction(recenterIcon, "Recenter", "Recenter map on rider", recenterIntent))

            // Zoom In Action
            val zoomInIntent = PendingIntent.getBroadcast(this, 2, Intent(ACTION_ZOOM_IN), flags)
            val zoomInIcon = Icon.createWithResource(this, android.R.drawable.ic_input_add)
            actions.add(RemoteAction(zoomInIcon, "Zoom In", "Zoom map in", zoomInIntent))

            // Zoom Out Action
            val zoomOutIntent = PendingIntent.getBroadcast(this, 3, Intent(ACTION_ZOOM_OUT), flags)
            val zoomOutIcon = Icon.createWithResource(this, android.R.drawable.ic_input_delete)
            actions.add(RemoteAction(zoomOutIcon, "Zoom Out", "Zoom map out", zoomOutIntent))
        }
        return actions
    }

    private fun triggerEnterPip(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            return try {
                val builder = PictureInPictureParams.Builder()
                builder.setAspectRatio(Rational(3, 4))
                builder.setActions(getPipActions())
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    builder.setAutoEnterEnabled(isPipEnabled)
                }
                enterPictureInPictureMode(builder.build())
            } catch (e: Exception) {
                false
            }
        }
        return false
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("pipModeChanged", isInPictureInPictureMode)
    }

    override fun onDestroy() {
        if (pipReceiver != null) {
            try {
                unregisterReceiver(pipReceiver)
            } catch (e: Exception) {}
        }
        super.onDestroy()
    }
}
