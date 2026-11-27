package community.reel.app.ui

import androidx.compose.ui.graphics.Color
import community.reel.core.AlertCenter
import community.reel.core.AppSettings
import community.reel.core.Library
import community.reel.core.TraktStore
import community.reel.core.UpcomingStore
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * What's waiting on you before the next thing plays: setup that stops streaming, a stopped sync,
 * new episodes of what you follow. Home shows these as cards; the count of those that need you is
 * the red badge on the Home tab.
 */
class Attention(settings: AppSettings, library: Library, trakt: TraktStore, upcoming: UpcomingStore) {
    sealed interface Action {
        data object Setup : Action
        data class Settings(val page: SettingsPage) : Action
        data object Calendar : Action
    }

    data class Item(val id: String, val title: String, val detail: String, val icon: Icons, val tint: Color,
                    /** Counts toward the badge: something you should do, not just news. */ val needsYou: Boolean, val action: Action)

    enum class Icons { SETUP, KEY, SYNC, NEW, TODAY }

    val items: List<Item>

    init {
        val list = mutableListOf<Item>()
        if (!settings.canFindSources) list += Item("setup", "Finish setting up".tr(), "Choose a debrid service or an addon so titles can play.".tr(),
            Icons.SETUP, Theme.attention, true, Action.Setup)
        val days = settings.debridAccount?.daysLeft
        if (settings.isDebridConfigured && days != null && days <= 7) list += Item("debrid.plan",
            if (days <= 0) "Debrid plan ends today".tr() else if (days == 1) "Debrid plan ends in 1 day".tr() else "Debrid plan ends in %d days".tr(days),
            "Renew %s, or streams stop when the plan ends.".tr(settings.debridService.title), Icons.KEY, Theme.warning, true, Action.Settings(SettingsPage.STATUS))
        trakt.syncError?.let { list += Item("trakt", "Trakt sync stopped".tr(), it, Icons.SYNC, Theme.warning, true, Action.Settings(SettingsPage.TRAKT)) }
        val fresh = upcoming.newEpisodes(library)
        if (fresh.isNotEmpty()) {
            val count = upcoming.newEpisodeCount(library)
            list += Item("episodes.new", if (count == 1) "1 new episode".tr() else "%d new episodes".tr(count),
                fresh.take(3).joinToString(", ") { it.item.name }, Icons.NEW, Theme.accent, true, Action.Calendar)
        }
        val today = upcoming.airingToday.filter { !it.hasAired }
        if (today.isNotEmpty()) {
            val time = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withZone(ZoneId.systemDefault())
            list += Item("episodes.today", if (today.size == 1) "1 episode airs today".tr() else "%d episodes air today".tr(today.size),
                today.take(2).joinToString(", ") { "${it.item.name} ${time.format(it.date)}" }, Icons.TODAY, Theme.accent, false, Action.Calendar)
        }
        items = list
    }

    val badgeCount: Int get() = items.count { it.needsYou }

    companion object {
        /** The settings gear's red dot: a problem only Settings can fix. */
        fun settingsNeedAttention(settings: AppSettings, trakt: TraktStore, alerts: AlertCenter) =
            !settings.canFindSources || trakt.syncError != null || alerts.unseenProblems > 0
    }
}
