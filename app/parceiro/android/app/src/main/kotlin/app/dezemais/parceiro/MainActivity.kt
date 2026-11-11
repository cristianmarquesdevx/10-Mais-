package app.dezemais.parceiro

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Ponte com o serviço de presença (primeiro plano). Quem chama é o
        // app do parceiro: "ficar online" liga o serviço, "ficar offline"
        // desliga. Sem isso (web, iOS, teste) o Dart segue funcionando — o
        // canal devolve false e o app segue publicando presença.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        try {
                            PresenceService.start(applicationContext)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("presence_service_start", e.message, null)
                        }
                    }
                    "stop" -> {
                        try {
                            PresenceService.stop(applicationContext)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("presence_service_stop", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    companion object {
        const val CHANNEL = "app.dezemais.parceiro/presence"
    }
}
