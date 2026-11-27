package community.reel.app.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import community.reel.core.AppStores

val LocalStores = staticCompositionLocalOf<AppStores> { error("No stores") }
val LocalRouter = staticCompositionLocalOf<AppRouter> { error("No router") }

/** The app's stores and router, for any screen. */
object Env {
    val stores: AppStores @Composable get() = LocalStores.current
    val router: AppRouter @Composable get() = LocalRouter.current
}
