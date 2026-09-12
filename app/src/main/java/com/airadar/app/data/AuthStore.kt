package com.airadar.app.data

import android.content.Context
import android.content.SharedPreferences
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/** Who is signed in, as the server describes them. */
data class AuthUser(
    val id: String,
    val email: String,
    val name: String?,
    val avatarUrl: String?,
    val givenName: String? = null,
    val color: String? = null,
    val findableByEmail: Boolean = false
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

    /** Profile fields changed after sign-in (colour, findability). */
    fun updateProfile(givenName: String?, color: String?, findableByEmail: Boolean) {
        prefs.edit()
            .putString("givenName", givenName)
            .putString("color", color)
            .putBoolean("findableByEmail", findableByEmail)
            .apply()
        _user.postValue(load())
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
            prefs.getBoolean("findableByEmail", false)
        )
    }
}
