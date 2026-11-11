package app.dezemais.parceiro

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

/**
 * Serviço em primeiro plano que mantém o app do parceiro VIVO enquanto ele
 * está ONLINE.
 *
 * Por que isso existe:
 *
 * O Android congela (e depois mata) apps que ficam em cache. Um parceiro que
 * deixa o app em segundo plano — a tela apagada, o celular no bolso, esperando
 * oferta — tinha o heartbeat suspenso pelo sistema. O servidor (Postgres)
 * só considera online quem deu sinal de vida nos últimos 90 s; sem heartbeat
 * o parceiro sumia do radar do passageiro e parava de receber oferta **sem
 * nenhum aviso no painel**. Era o bug "o parceiro não fica online".
 *
 * O serviço em primeiro plano resolve pela raiz:
 *   * o processo não é congelado nem morto pelo Android;
 *   * o isolate do Dart continua rodando, então o heartbeat continua batendo;
 *   * a notificação deixa o estado visível para o motorista (e para o usuário
 *     entender por que a notificação existe).
 *
 * O serviço NÃO publica nada por si: quem publica a presença é o app
 * (POST /radar/presence). Aqui só se segura o processo vivo.
 */
class PresenceService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = buildNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Android 14+ recusa serviço do tipo `location` sem a permissão de
            // localização concedida no momento. Sem serviço, o app ainda
            // funciona — só perde a garantia de sobreviver em segundo plano.
            Log.w(TAG, "não consegui ir para primeiro plano: ${e.message}")
            stopSelf()
            return START_NOT_STICKY
        }
        // START_NOT_STICKY (e não STICKY): se o Android matar o processo, o
        // serviço NÃO volta sozinho — quem publica a presença é o isolate do
        // Dart, e uma notificação "Você está online" sem ninguém publicando
        // seria mentira. O parceiro reabre o app e volta a ficar online.
        return START_NOT_STICKY
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Presença online",
            NotificationManager.IMPORTANCE_LOW,
        )
        channel.description = "Mostra que o 10 é + está com sua presença ativa."
        channel.setShowBadge(false)
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setContentTitle("Você está online")
            .setContentText("Sua presença está ativa no 10 é +.")
            .setSmallIcon(R.drawable.ic_notification)
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(openApp())
            .build()
    }

    /** Tocar na notificação abre o app (o motorista não cai num limbo). */
    private fun openApp(): PendingIntent? {
        val intent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        intent.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        return PendingIntent.getActivity(this, 0, intent, flags)
    }

    companion object {
        private const val TAG = "PresenceService"
        const val CHANNEL_ID = "ten_presenca"
        const val NOTIFICATION_ID = 4711

        /** Liga o serviço (idempotente). */
        fun start(context: Context) {
            val intent = Intent(context, PresenceService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        /** Desliga o serviço (o parceiro ficou offline). */
        fun stop(context: Context) {
            context.stopService(Intent(context, PresenceService::class.java))
        }
    }
}
