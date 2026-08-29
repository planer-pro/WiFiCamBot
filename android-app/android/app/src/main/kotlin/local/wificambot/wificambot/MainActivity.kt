package local.wificambot.wificambot

import android.hardware.input.InputManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var lastAxesSent = 0L
    // событие, отложенное троттлингом (см. dispatchGenericMotionEvent)
    private var pendingX = 0f
    private var pendingY = 0f
    private var pendingPosted = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // События геймпадов: список устройств + левый стик (~каждые 50 мс).
        // Bluetooth-геймпад для Android — обычное устройство ввода,
        // разрешений не нужно.
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "wificambot/gamepad")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                    eventSink = sink
                    sendDevices()
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })

        // Служебные команды окна (не гасить экран во время управления).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "wificambot/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "keepScreenOn" -> {
                        val on = call.arguments as? Boolean ?: false
                        if (on) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        // подключение/отключение геймпадов
        (getSystemService(INPUT_SERVICE) as InputManager).registerInputDeviceListener(
            object : InputManager.InputDeviceListener {
                override fun onInputDeviceAdded(deviceId: Int) = sendDevices()
                override fun onInputDeviceRemoved(deviceId: Int) = sendDevices()
                override fun onInputDeviceChanged(deviceId: Int) = sendDevices()
            },
            mainHandler
        )
    }

    private fun gamepadNames(): List<String> =
        InputDevice.getDeviceIds().toList()
            .mapNotNull { id -> InputDevice.getDevice(id) }
            .filter { d -> (d.sources and InputDevice.SOURCE_CLASS_JOYSTICK) != 0 }
            .map { d -> d.name }
            .distinct()

    private fun sendDevices() {
        mainHandler.post {
            eventSink?.success(
                mapOf("type" to "devices", "names" to gamepadNames())
            )
        }
    }

    override fun dispatchGenericMotionEvent(event: MotionEvent?): Boolean {
        val e = event ?: return super.dispatchGenericMotionEvent(event)
        if ((e.source and InputDevice.SOURCE_CLASS_JOYSTICK) != 0 &&
            e.action == MotionEvent.ACTION_MOVE
        ) {
            val now = SystemClock.elapsedRealtime()
            val x = e.getAxisValue(MotionEvent.AXIS_X)
            val y = e.getAxisValue(MotionEvent.AXIS_Y)
            if (now - lastAxesSent >= 50) {
                lastAxesSent = now
                sendAxes(x, y)
            } else if (!pendingPosted) {
                // Не отбрасываем, а откладываем до конца окна троттлинга:
                // иначе теряется ПОСЛЕДНЕЕ событие — возврат стика в ноль при
                // отпускании (индикатор в клиенте замирал отклонённым, моторы
                // продолжали повторять последнюю команду).
                pendingX = x
                pendingY = y
                pendingPosted = true
                mainHandler.postDelayed({
                    pendingPosted = false
                    if (eventSink != null) {
                        lastAxesSent = SystemClock.elapsedRealtime()
                        sendAxes(pendingX, pendingY)
                    }
                }, 50 - (now - lastAxesSent))
            } else {
                pendingX = x
                pendingY = y
            }
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }

    private fun sendAxes(x: Float, y: Float) {
        mainHandler.post {
            eventSink?.success(mapOf("type" to "axes", "x" to x, "y" to y))
        }
    }
}
