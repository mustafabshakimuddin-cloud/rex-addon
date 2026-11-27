package community.reel.core

import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import java.io.File
import java.time.Duration
import java.util.UUID

/** A list of your own beyond My List: "Christmas films", "To watch with Sam". */
@Serializable
data class CustomList(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val items: List<MediaItem> = emptyList(),
    val createdAt: Date = now(),
)

/** Your own lists, kept in a JSON file like the library. */
class ListsStore(file: File = JSONFile.file("lists.json")) : Observed() {
    var lists: List<CustomList> = emptyList(); private set
    private var writer = SnapshotWriter(file)

    init { lists = JSONFile.read(file) { it.lossyList<CustomList>() } ?: emptyList() }

    /** Loads another profile's lists. */
    fun load(file: File) {
        saveNow()
        writer.waitUntilWritten()
        writer = SnapshotWriter(file)
        lists = JSONFile.read(file) { it.lossyList<CustomList>() } ?: emptyList()
        changed()
    }

    fun list(id: String) = lists.firstOrNull { it.id == id }

    fun create(name: String, item: MediaItem? = null): CustomList {
        val trimmed = name.trim()
        val list = CustomList(name = trimmed.ifEmpty { "New List" }, items = listOfNotNull(item))
        lists = lists + list
        save()
        return list
    }

    fun rename(id: String, name: String) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) return
        lists = lists.map { if (it.id == id) it.copy(name = trimmed) else it }
        save()
    }

    fun delete(id: String) {
        lists = lists.filter { it.id != id }
        save()
    }

    fun contains(item: MediaItem, id: String) = list(id)?.items?.any { it.id == item.id } ?: false

    /** Adds the title, or takes it off when it is already there. */
    fun toggle(item: MediaItem, id: String) {
        lists = lists.map { list ->
            if (list.id != id) list
            else if (list.items.any { it.id == item.id }) list.copy(items = list.items.filter { it.id != item.id })
            else list.copy(items = listOf(item) + list.items)
        }
        save()
    }

    /** The lists a title is on, for its page. */
    fun listsContaining(item: MediaItem) = lists.filter { list -> list.items.any { it.id == item.id } }

    fun replaceAll(lists: List<CustomList>) {
        this.lists = lists
        save()
    }

    private fun save() {
        changed()
        val snapshot = lists
        writer.schedule(0.4) { ReelJson.encodeToString(snapshot) }
    }

    fun saveNow() {
        val snapshot = lists
        writer.flush { ReelJson.encodeToString(snapshot) }
    }

    fun waitForSave() = writer.waitUntilWritten()
}

/**
 * Someone who watches on this device. Each has their own My List, history, resume points, lists,
 * player choices and Trakt account; the debrid service, addons and settings are shared.
 */
@Serializable
data class Profile(
    val id: String,
    val name: String,
    val symbol: String,
    /** Shows only family and animation titles in lists, rows and search. */
    val isKids: Boolean = false,
) {
    val isDefault: Boolean get() = id == DEFAULT_ID

    /** The default profile keeps the names from before profiles existed, so nothing moves. */
    fun file(base: String): File = if (isDefault) JSONFile.file("$base.json") else JSONFile.file("$base-$id.json")

    /** A settings or secure-storage key for this profile. */
    fun key(base: String) = if (isDefault) base else "$base.$id"

    companion object {
        const val DEFAULT_ID = "default"
        val symbols = listOf("person", "star", "heart", "moon", "flame", "leaf", "pets", "games")
        val default get() = Profile(DEFAULT_ID, "Me", "person")
    }
}

class ProfileStore : Observed() {
    var profiles: List<Profile>; private set
    var current: Profile; private set

    private val defaults get() = Platform.defaults

    init {
        val saved = defaults.string(PROFILES)?.let { runCatching { ReelJson.decodeFromString<List<Profile>>(it) }.getOrNull() }?.toMutableList()
            ?: mutableListOf()
        if (saved.none { it.isDefault }) saved.add(0, Profile.default)
        profiles = saved
        val currentID = defaults.string(CURRENT) ?: Profile.DEFAULT_ID
        current = saved.firstOrNull { it.id == currentID } ?: saved[0]
        currentKeySuffix = if (current.isDefault) "" else ".${current.id}"
    }

    val hasSeveral: Boolean get() = profiles.size > 1

    fun add(name: String, symbol: String, isKids: Boolean): Profile {
        val trimmed = name.trim()
        val profile = Profile(UUID.randomUUID().toString().lowercase(), trimmed.ifEmpty { "New Profile" }, symbol, isKids)
        profiles = profiles + profile
        save()
        return profile
    }

    fun update(profile: Profile) {
        if (profiles.none { it.id == profile.id }) return
        profiles = profiles.map { if (it.id == profile.id) profile else it }
        if (current.id == profile.id) current = profile
        save()
    }

    /** Deletes a profile and its files. The default profile stays. */
    fun delete(profile: Profile) {
        if (profile.isDefault || profile.id == current.id) return
        profiles = profiles.filter { it.id != profile.id }
        for (base in listOf("library", "lists", "trakt-queue")) profile.file(base).delete()
        defaults.remove(profile.key("player.choices"))
        defaults.remove(profile.key("trakt.lastActivities"))
        Platform.secrets.write("", profile.key("trakt.token"))
        save()
    }

    fun select(profile: Profile) {
        val match = profiles.firstOrNull { it.id == profile.id } ?: return
        current = match
        currentKeySuffix = if (match.isDefault) "" else ".${match.id}"
        defaults.putString(CURRENT, match.id)
        changed()
    }

    private fun save() {
        defaults.putString(PROFILES, ReelJson.encodeToString(profiles))
        changed()
    }

    companion object {
        private const val PROFILES = "profiles.list"
        private const val CURRENT = "profiles.current"
        /** The current profile's key suffix, read by stores that keep small things in settings. */
        @Volatile var currentKeySuffix = ""
    }
}

/** Something worth telling you about: a download that finished or failed, a sync that broke. */
@Serializable
data class AppAlert(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val message: String? = null,
    val level: Level,
    val action: Action? = null,
    val date: Date = now(),
) {
    @Serializable enum class Level { INFO, SUCCESS, WARNING, PROBLEM }
    @Serializable enum class Action { OPEN_DOWNLOADS, OPEN_STATUS, OPEN_TRAKT, OPEN_SETUP }

    val actionTitle: String?
        get() = when (action) {
            Action.OPEN_DOWNLOADS -> "Downloads"
            Action.OPEN_STATUS -> "Status"
            Action.OPEN_TRAKT -> "Trakt"
            Action.OPEN_SETUP -> "Set Up"
            null -> null
        }
}

/**
 * Pop-ups and the list of recent alerts under Settings → Status. A pop-up shows for a few seconds
 * over whatever is on screen; the list keeps the last few dozen across launches.
 */
class AlertCenter : Observed() {
    var current: AppAlert? = null; private set
    var recent: List<AppAlert> = emptyList(); private set
    /** Alerts not yet seen in the list; Settings shows a red dot while there are problems among them. */
    var unseenProblems = 0
        private set(value) { field = value; Platform.defaults.putInt(UNSEEN, value) }

    private var dismissJob: Job? = null
    private val queue = ArrayDeque<AppAlert>()

    init {
        recent = Platform.defaults.string(KEY)?.let { runCatching { ReelJson.decodeFromString<List<AppAlert>>(it) }.getOrNull() } ?: emptyList()
        unseenProblems = Platform.defaults.int(UNSEEN) ?: 0
    }

    fun post(title: String, message: String? = null, level: AppAlert.Level = AppAlert.Level.INFO,
             action: AppAlert.Action? = null, popUp: Boolean = true) {
        val alert = AppAlert(title = title, message = message, level = level, action = action)
        // The same problem reported again within a minute (a sync retried) is one alert, not two.
        val last = recent.firstOrNull()
        if (last != null && last.title == alert.title && last.message == alert.message &&
            Duration.between(last.date, alert.date).seconds < 60) return
        recent = (listOf(alert) + recent).take(KEEP)
        if (alert.level == AppAlert.Level.PROBLEM || alert.level == AppAlert.Level.WARNING) unseenProblems += 1
        save()
        changed()
        if (!popUp) return
        if (current == null) show(alert) else queue.addLast(alert)
    }

    fun dismissCurrent() {
        dismissJob?.cancel()
        current = null
        changed()
        val next = queue.removeFirstOrNull() ?: return
        Platform.scope.launch {
            delay(350)
            show(next)
        }
    }

    fun markSeen() { unseenProblems = 0; changed() }

    fun clear() {
        recent = emptyList()
        unseenProblems = 0
        save()
        changed()
    }

    private fun show(alert: AppAlert) {
        current = alert
        changed()
        dismissJob?.cancel()
        dismissJob = Platform.scope.launch {
            delay(if (alert.level == AppAlert.Level.PROBLEM) 6000 else 4000)
            if (current?.id == alert.id) dismissCurrent()
        }
    }

    private fun save() = Platform.defaults.putString(KEY, ReelJson.encodeToString(recent))

    companion object {
        private const val KEY = "alerts.recent"
        private const val UNSEEN = "alerts.unseenProblems"
        private const val KEEP = 40
    }
}

/**
 * The choices made in the player for one film or series: audio and subtitle language, subtitle
 * timing, fill and speed. The next episode starts the way the last one was left.
 */
@Serializable
data class ViewingChoice(
    /** ISO language of the audio track picked; null follows the settings. */
    val audioLanguage: String? = null,
    /** ISO language of the subtitle track picked, "" for subtitles off; null follows the settings. */
    val subtitleLanguage: String? = null,
    val subtitleDelay: Double = 0.0,
    val fillsScreen: Boolean = false,
    val rate: Float = 1f,
    val updatedAt: Date = now(),
    /** Where you skipped from and to near the start of an episode, for the next ones. */
    val introStart: Double? = null,
    val introEnd: Double? = null,
)

object ViewingPreferences {
    private val key: String get() = "player.choices" + ProfileStore.currentKeySuffix
    private const val KEEP = 300

    fun choice(titleID: String): ViewingChoice? = all()[titleID]

    fun store(choice: ViewingChoice, titleID: String) {
        var all = all() + (titleID to choice)
        if (all.size > KEEP) {
            val drop = all.entries.sortedBy { it.value.updatedAt }.take(all.size - KEEP).map { it.key }.toSet()
            all = all.filterKeys { it !in drop }
        }
        Platform.defaults.putString(key, ReelJson.encodeToString(all))
    }

    fun forgetAll() = Platform.defaults.remove(key)

    private fun all(): Map<String, ViewingChoice> =
        Platform.defaults.string(key)?.let { runCatching { ReelJson.decodeFromString<Map<String, ViewingChoice>>(it) }.getOrNull() } ?: emptyMap()
}
