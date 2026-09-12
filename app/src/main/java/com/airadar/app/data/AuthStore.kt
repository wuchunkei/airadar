package com.airadar.app.data

import android.content.Context
import android.content.SharedPreferences
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.time.Instant

/** Who is signed in, as the server describes them. */
data class AuthUser(
    val id: String,
    val email: String,
    val name: String?,
    val avatarUrl: String?,
    val givenName: String? = null,
    val color: String? = null,
    val findableByEmail: Boolean = false,
    val membership: Membership = Membership.GUEST
)

/**
 * The signed-in session, kept in encrypted preferences so the refresh token
 * survives restarts without sitting in plain text on disk. [init] once from the
 * Activity; everything else is static.
 */
object AuthStore {

    private lateinit var prefs: SharedPreferences

    private val _user = MutableLiveData<AuthUser?>(null)
    val user: LiveData<AuthUser?> = _user

    fun init(context: Context) {
        if (::prefs.isInitialized) return
        val key = MasterKey.Builder(context.applicationContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        prefs = EncryptedSharedPreferences.create(
            context.applicationContext,
            "auth",
            key,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
        _user.value = load()
    }

    val isSignedIn: Boolean get() = ::prefs.isInitialized && prefs.getString("refreshToken", null) != null

    val accessToken: String? get() = prefs.getString("accessToken", null)
    val refreshToken: String? get() = prefs.getString("refreshToken", null)

    fun save(accessToken: String, refreshToken: String, user: AuthUser) {
        prefs.edit()
            .putString("accessToken", accessToken)
            .putString("refreshToken", refreshToken)
            .putString("userId", user.id)
            .putString("email", user.email)
            .putString("name", user.name)
            .putString("avatarUrl", user.avatarUrl)
            .putString("givenName", user.givenName)
            .putString("color", user.color)
            .putBoolean("findableByEmail", user.findableByEmail)
            .apply()
        _user.postValue(user)
    }

    /** Profile fields changed after sign-in (colour, findability, plan). */
    fun updateProfile(givenName: String?, color: String?, findableByEmail: Boolean, membership: Membership? = null) {
        prefs.edit()
            .putString("givenName", givenName)
            .putString("color", color)
            .putBoolean("findableByEmail", findableByEmail)
            .apply()
        membership?.let(::saveMembership)
        _user.postValue(load())
    }

    fun saveMembership(m: Membership) {
        prefs.edit()
            .putString("tier", m.tier.name)
            .putLong("tierUntil", m.until?.toEpochMilli() ?: 0L)
            .putBoolean("tierTrial", m.trial)
            .apply()
        _user.postValue(load())
    }

    private fun loadMembership(): Membership {
        val tier = runCatching { Tier.valueOf(prefs.getString("tier", null) ?: "") }.getOrDefault(Tier.GUEST)
        val until = prefs.getLong("tierUntil", 0L).takeIf { it > 0 }?.let(Instant::ofEpochMilli)
        // A lapsed plan is a guest plan until the server says otherwise.
        val lapsed = until != null && until.isBefore(Instant.now())
        return Membership(if (lapsed) Tier.GUEST else tier, until, prefs.getBoolean("tierTrial", false))
    }

    fun clear() {
        prefs.edit().clear().apply()
        _user.postValue(null)
    }

    private fun load(): AuthUser? {
        val id = prefs.getString("userId", null) ?: return null
        val email = prefs.getString("email", null) ?: return null
        return AuthUser(
            id, email, prefs.getString("name", null), prefs.getString("avatarUrl", null),
            prefs.getString("givenName", null), prefs.getString("color", null),
            prefs.getBoolean("findableByEmail", false),
            loadMembership()
        )
    }
}
