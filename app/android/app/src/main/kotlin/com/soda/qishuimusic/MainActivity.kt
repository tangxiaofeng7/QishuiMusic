package com.soda.qishuimusic

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.webkit.CookieManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 官方网页登录：读 WebView 全局 CookieManager（含 HttpOnly 的
        // sessionid_ss）。webview_flutter 未在 Android 侧暴露查询接口，故走 channel。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sodam/web_cookies")
            .setMethodCallHandler { call, result ->
                if (call.method == "getCookies") {
                    val url = call.arguments as? String
                    if (url.isNullOrEmpty()) {
                        result.error("invalid_args", "url required", null)
                    } else {
                        result.success(CookieManager.getInstance().getCookie(url))
                    }
                } else {
                    result.notImplemented()
                }
            }
        // 原生能力桥（与 iOS AppDelegate 同名通道）：
        // openUrl / canOpenUrl（交流群跳转）/ deviceInfo（设置页运行环境展示）。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sodam/platform")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openUrl" -> {
                        val url = (call.arguments as? Map<*, *>)?.get("url") as? String
                        if (url.isNullOrEmpty()) {
                            result.error("args", "url missing", null)
                        } else {
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
                                result.success(true)
                            } catch (_: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    "canOpenUrl" -> {
                        val url = (call.arguments as? Map<*, *>)?.get("url") as? String
                        if (url.isNullOrEmpty()) {
                            result.error("args", "url missing", null)
                        } else {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            result.success(intent.resolveActivity(packageManager) != null)
                        }
                    }
                    "deviceInfo" -> result.success(
                        // 注意括号：中缀 to 优先级高于 ?:，不括起来会解析成
                        // (Pair ?: "")，elvis 结果类型退化为 Serializable 导致编译失败
                        mapOf(
                            "os" to "Android",
                            "osVersion" to (Build.VERSION.RELEASE ?: ""),
                            "model" to (Build.MODEL ?: ""),
                            "machine" to (Build.DEVICE ?: ""),
                            "simulator" to isEmulator().toString(),
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun isEmulator(): Boolean =
        Build.FINGERPRINT.contains("generic") ||
            Build.FINGERPRINT.contains("emulator") ||
            Build.MODEL.contains("Emulator") ||
            Build.MODEL.contains("Android SDK built for") ||
            Build.PRODUCT == "google_sdk" ||
            Build.HARDWARE.contains("ranchu")
}
