package ano.subcase.util

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.edit
import ano.subcase.caseApp
import ano.subcase.util.PreferencesKeys.ALLOW_CRASH_REPORT
import ano.subcase.util.PreferencesKeys.ALLOW_LAN
import ano.subcase.util.PreferencesKeys.APP_IS_FIRST_OPEN
import ano.subcase.util.PreferencesKeys.BACKEND_LOCAL_VER
import ano.subcase.util.PreferencesKeys.FRONTEND_LOCAL_VER
import ano.subcase.util.PreferencesKeys.LEGACY_NODE_MIGRATED
import ano.subcase.util.PreferencesKeys.REMOTE_BACKEND_URL

object PreferencesKeys {
    const val HOME_PANEL_VERTICAL_FRACTION = "home_panel_vertical_fraction"
    const val NOTIFICATION_PERMISSION_REQUESTED = "notification_permission_requested"

    const val APP_IS_FIRST_OPEN = "app_first_open"

    const val ALLOW_LAN = "allow_lan"
    const val ALLOW_CRASH_REPORT = "allow_crash_report"

    const val REMOTE_BACKEND_URL = "remote_backend_url"

    const val BACKEND_LOCAL_VER = "backend_local_ver"
    const val FRONTEND_LOCAL_VER = "frontend_local_ver"

    const val SUBSTORE_UPDATE_POLICY = "substore_update_policy"
    const val LAST_FRONTEND_INSTALLED_AT = "last_frontend_installed_at"
    const val LAST_BACKEND_INSTALLED_AT = "last_backend_installed_at"
    const val LAST_SUBSTORE_REMOTE_VERSION_CHECK_AT = "last_substore_remote_version_check_at"

    const val LEGACY_NODE_MIGRATED = "legacy_node_migrated"
}

object ConfigStore {
    val homePanelVerticalFraction: Float?
        get() = getInstance()
            .getFloat(PreferencesKeys.HOME_PANEL_VERTICAL_FRACTION, Float.NaN)
            .takeIf { it.isFinite() }
            ?.coerceIn(0f, 1f)

    /** Call from an IO dispatcher; commit reports disk write failures. */
    fun saveHomePanelVerticalFraction(fraction: Float) {
        require(fraction.isFinite() && fraction in 0f..1f)
        check(getInstance().edit()
            .putFloat(PreferencesKeys.HOME_PANEL_VERTICAL_FRACTION, fraction)
            .commit()) { "Failed to save home panel position" }
    }

    private var prefs: SharedPreferences? = null

    fun getInstance(): SharedPreferences {
        if (prefs == null) {
            prefs = caseApp.getSharedPreferences("settings", Context.MODE_PRIVATE)
        }
        return prefs!!
    }

    var notificationPermissionRequested: Boolean
        get() = getInstance().getBoolean(PreferencesKeys.NOTIFICATION_PERMISSION_REQUESTED, false)
        set(value) {
            getInstance().edit { putBoolean(PreferencesKeys.NOTIFICATION_PERMISSION_REQUESTED, value) }
        }

    var isFirstOpen: Boolean
        get() = getInstance().getBoolean(APP_IS_FIRST_OPEN, true)
        set(value) {
            getInstance().edit { putBoolean(APP_IS_FIRST_OPEN, value) }
        }

    var isAllowLan: Boolean
        get() = getInstance().getBoolean(ALLOW_LAN, false)
        set(value) {
            getInstance().edit { putBoolean(ALLOW_LAN, value) }
        }

    var isAllowCrashReport: Boolean
        get() = getInstance().getBoolean(ALLOW_CRASH_REPORT, true)
        set(value) {
            getInstance().edit { putBoolean(ALLOW_CRASH_REPORT, value) }
        }

    /**
     * 自建 Sub-Store 后端地址（形如 https://host/path）。
     * 为空时使用 App 内置的本地后端；非空时前端通过 ?api= 指向该远端后端。
     * 用 State 承载，设置页保存后首页才能重组并让 WebView 重新加载。
     * 惰性初始化，避免 object 构造时 caseApp 尚未就绪。
     */
    private val remoteBackendUrlState by lazy {
        mutableStateOf(getInstance().getString(REMOTE_BACKEND_URL, "")!!.trim())
    }

    var remoteBackendUrl: String
        get() = remoteBackendUrlState.value
        set(value) {
            val trimmed = value.trim()
            getInstance().edit { putString(REMOTE_BACKEND_URL, trimmed) }
            remoteBackendUrlState.value = trimmed
        }

    var localFrontendVersion: String
        get() = getInstance().getString(FRONTEND_LOCAL_VER, "")!!
        set(value) {
            getInstance().edit { putString(FRONTEND_LOCAL_VER, value) }
        }

    var localBackendVersion: String
        get() = getInstance().getString(BACKEND_LOCAL_VER, "")!!
        set(value) {
            getInstance().edit { putString(BACKEND_LOCAL_VER, value) }
        }

    var subStoreUpdatePolicy: SubStoreUpdatePolicy
        get() = SubStoreUpdatePolicy.fromStored(
            getInstance().getString(PreferencesKeys.SUBSTORE_UPDATE_POLICY, null),
        )
        set(value) {
            getInstance().edit {
                putString(PreferencesKeys.SUBSTORE_UPDATE_POLICY, value.name)
            }
        }

    var lastFrontendInstalledAt: Long
        get() = getInstance().getLong(PreferencesKeys.LAST_FRONTEND_INSTALLED_AT, 0L)
        set(value) {
            getInstance().edit { putLong(PreferencesKeys.LAST_FRONTEND_INSTALLED_AT, value) }
        }

    var lastBackendInstalledAt: Long
        get() = getInstance().getLong(PreferencesKeys.LAST_BACKEND_INSTALLED_AT, 0L)
        set(value) {
            getInstance().edit { putLong(PreferencesKeys.LAST_BACKEND_INSTALLED_AT, value) }
        }

    var lastSubStoreRemoteVersionCheckAt: Long
        get() = getInstance().getLong(PreferencesKeys.LAST_SUBSTORE_REMOTE_VERSION_CHECK_AT, 0L)
        set(value) {
            getInstance().edit {
                putLong(PreferencesKeys.LAST_SUBSTORE_REMOTE_VERSION_CHECK_AT, value)
            }
        }

    var legacyNodeMigrated: Boolean
        get() = getInstance().getBoolean(LEGACY_NODE_MIGRATED, false)
        set(value) {
            check(getInstance().edit().putBoolean(LEGACY_NODE_MIGRATED, value).commit())
        }
}
