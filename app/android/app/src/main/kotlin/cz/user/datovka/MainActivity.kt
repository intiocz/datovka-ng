package cz.user.datovka

import android.content.ActivityNotFoundException
import android.content.Intent
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cz.datovka/android")
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "secretKey" -> result.success(secretKey())
                        "open" -> result.success(open(call.arguments as String, false))
                        "share" -> result.success(open(call.arguments as String, true))
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("android", e.message, null)
                }
            }
    }

    /// A random key for the passwords file. It is stored only wrapped by a
    /// key that never leaves the Android Keystore.
    private fun secretKey(): ByteArray {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(ALIAS)) {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").run {
                init(
                    KeyGenParameterSpec.Builder(
                        ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build(),
                )
                generateKey()
            }
        }
        val wrap = store.getKey(ALIAS, null) as SecretKey
        val prefs = getSharedPreferences("datovka_keystore", MODE_PRIVATE)
        prefs.getString("wrapped", null)?.let {
            val data = Base64.decode(it, Base64.NO_WRAP)
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, wrap, GCMParameterSpec(128, data, 0, 12))
            return c.doFinal(data, 12, data.size - 12)
        }
        val key = ByteArray(32).also { SecureRandom().nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, wrap)
        val wrapped = c.iv + c.doFinal(key)
        prefs.edit().putString("wrapped", Base64.encodeToString(wrapped, Base64.NO_WRAP)).apply()
        return key
    }

    /// Opens a file of the app in another app, or offers it for sharing.
    private fun open(path: String, share: Boolean): Boolean {
        val file = File(path)
        val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
        val type = MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(file.extension.lowercase()) ?: "application/octet-stream"
        val intent = if (share) {
            Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uri)
        } else {
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, type)
        }.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        return try {
            startActivity(Intent.createChooser(intent, null))
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    companion object {
        private const val ALIAS = "datovka-passwords"
    }
}
