package community.reel.app.system

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities

/** Whether the device has a usable network, so a failure offline isn't held against a source. */
object Network {
    fun isOnline(context: Context): Boolean {
        val manager = context.getSystemService(ConnectivityManager::class.java) ?: return true
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }
}
