package community.reel.app.system

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import java.io.ByteArrayOutputStream

/** Mock mode's pictures: a soft gradient picked from the address, the same on every run. */
object MockPictures {
    fun png(key: String): ByteArray {
        val hue = key.fold(0) { acc, c -> (acc * 31 + c.code) % 360 }.toFloat()
        val bitmap = Bitmap.createBitmap(300, 450, Bitmap.Config.ARGB_8888)
        val paint = Paint().apply {
            shader = LinearGradient(0f, 0f, 300f, 450f, Color.HSVToColor(floatArrayOf(hue, 0.55f, 0.55f)),
                Color.HSVToColor(floatArrayOf(hue, 0.7f, 0.2f)), Shader.TileMode.CLAMP)
        }
        Canvas(bitmap).drawRect(0f, 0f, 300f, 450f, paint)
        return ByteArrayOutputStream().also { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }.toByteArray()
    }
}
