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
            if (now - lastAxesSent >= 50) {
                lastAxesSent = now
                val x = e.getAxisValue(MotionEvent.AXIS_X)
                val y = e.getAxisValue(MotionEvent.AXIS_Y)
                mainHandler.post {
                    eventSink?.success(mapOf("type" to "axes", "x" to x, "y" to y))
                }
            }
            return true
        }
        return super.dispatchGenericMotionEvent(event)
    }
}
