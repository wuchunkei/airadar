package com.airadar.app.data

import android.content.Context
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import androidx.credentials.exceptions.GetCredentialCancellationException
import androidx.credentials.exceptions.GetCredentialException
import androidx.credentials.exceptions.NoCredentialException
import com.airadar.app.BuildConfig
import com.google.android.libraries.identity.googleid.GetGoogleIdOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import java.io.IOException

/**
 * Google's own account picker, through Android's Credential Manager. What comes
 * back is an ID token signed by Google; the server verifies it and issues its own.
 */
object GoogleSignIn {

    class Cancelled : IOException("Sign-in cancelled.")

    val isConfigured: Boolean get() = BuildConfig.GOOGLE_WEB_CLIENT_ID.isNotBlank()

    /** [activity] must be an Activity context: the picker is a system sheet over it. */
    suspend fun idToken(activity: Context): String {
        if (!isConfigured) {
            throw IOException("Google sign-in is not configured — set google.webClientId in local.properties.")
        }
        val option = GetGoogleIdOption.Builder()
            // Show every Google account on the phone, not only ones used here before.
            .setFilterByAuthorizedAccounts(false)
            .setServerClientId(BuildConfig.GOOGLE_WEB_CLIENT_ID)
            .setAutoSelectEnabled(true)
            .build()
        val request = GetCredentialRequest.Builder().addCredentialOption(option).build()

        val credential = try {
            CredentialManager.create(activity).getCredential(activity, request).credential
        } catch (e: GetCredentialCancellationException) {
            throw Cancelled()
        } catch (e: NoCredentialException) {
            throw IOException("No Google account on this phone. Add one in Android Settings first.")
        } catch (e: GetCredentialException) {
            throw IOException("Google sign-in failed: ${e.message ?: e.type}")
        }

        if (credential is CustomCredential &&
            credential.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL
        ) {
            return GoogleIdTokenCredential.createFrom(credential.data).idToken
        }
        throw IOException("Google returned an unexpected credential type.")
    }
}
