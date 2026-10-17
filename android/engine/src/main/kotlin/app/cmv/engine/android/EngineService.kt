package app.cmv.engine.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * 前台服务：让引擎在界面关掉后继续跑（通知栏常驻，带「停止」按钮），并承载 MediaProjection（Android 14+ 要求）。
 * 引擎本身是进程内单例（AndroidControllerEngine.get），服务只负责「前台」身份。
 *
 * 调试入口（不需要界面）：
 *   adb shell am start-foreground-service -n app.cmv/app.cmv.engine.android.EngineService --es cmd start
 *   … --es cmd stop
 *   … --es cmd set --es target 0 --es json '{"source":"按摩","preset":"捶背"}'
 *   … --es cmd access            （第一个手柄申请 USB 直连 / HID 访问）
 *   状态快照输出到 logcat（tag cv-engine）
 */
class EngineService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val engine = AndroidControllerEngine.get(this)
        when (intent?.action) {
            ACTION_STOP -> { engine.stop(); return START_NOT_STICKY }
            ACTION_PROJECTION -> {
                goForeground(projection = true)
                engine.onProjectionForeground()
                return START_NOT_STICKY
            }
            ACTION_END -> {
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
        }
        goForeground(projection = false)
        intent?.getStringExtra("cmd")?.let { cmd ->
            Log.i(AndroidControllerEngine.TAG, "debug command: $cmd")
            engine.debugCommand(cmd, intent.getStringExtra("target"), intent.getStringExtra("json"))
        }
        return START_NOT_STICKY
    }

    private var projectionType = false

    private fun goForeground(projection: Boolean) {
        projectionType = projectionType || projection
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Controller Music Visualizer", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 1, Intent(this, EngineService::class.java).setAction(ACTION_STOP),
                                            PendingIntent.FLAG_IMMUTABLE)
        val open = packageManager.getLaunchIntentForPackage(packageName)?.let {
            PendingIntent.getActivity(this, 2, it, PendingIntent.FLAG_IMMUTABLE)
        }
        val n: Notification = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("手柄音乐可视化 · 运行中 / Running")
            .setContentText("手柄正在跟随音乐或按摩 · Controllers are active")
            .setOngoing(true)
            .setContentIntent(open)
            .addAction(android.R.drawable.ic_media_pause, "停止 / Stop", stop)
            .build()
        var type = ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        if (projectionType) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
        ServiceCompat.startForeground(this, NOTIFICATION_ID, n, if (Build.VERSION.SDK_INT >= 29) type else 0)
    }

    companion object {
        private const val CHANNEL = "engine"
        private const val NOTIFICATION_ID = 1
        private const val ACTION_STOP = "app.cmv.STOP"
        private const val ACTION_PROJECTION = "app.cmv.PROJECTION"
        private const val ACTION_END = "app.cmv.END"

        fun start(context: Context) =
            ContextCompat.startForegroundService(context, Intent(context, EngineService::class.java))

        fun startProjection(context: Context) =
            ContextCompat.startForegroundService(context, Intent(context, EngineService::class.java).setAction(ACTION_PROJECTION))

        fun stop(context: Context) {
            runCatching { context.startService(Intent(context, EngineService::class.java).setAction(ACTION_END)) }
        }
    }
}
