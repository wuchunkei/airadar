package com.airadar.app.data

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import com.google.android.gms.location.LocationServices
import java.util.Locale
import kotlin.coroutines.resume
import kotlinx.coroutines.suspendCancellableCoroutine

/** Somewhere to look when there are no trips to frame yet. */
data class Region(val latitude: Double, val longitude: Double, val zoom: Double)

/**
 * Where the traveller roughly is, without asking for anything precise. With
 * coarse location granted the phone's last fix is used (city-level); otherwise
 * the SIM's or the phone's country, centred, at a zoom that shows the country.
 */
object HomeRegion {

    suspend fun find(context: Context): Region {
        coarseFix(context)?.let { return it }
        val country = countryCode(context)
        return countries[country] ?: Region(20.0, 0.0, 2.0)
    }

    private suspend fun coarseFix(context: Context): Region? {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        if (!granted) return null
        return try {
            suspendCancellableCoroutine { cont ->
                LocationServices.getFusedLocationProviderClient(context).lastLocation
                    .addOnSuccessListener { loc ->
                        cont.resume(loc?.let { Region(it.latitude, it.longitude, 6.0) })
                    }
                    .addOnFailureListener { cont.resume(null) }
            }
        } catch (_: SecurityException) {
            null
        }
    }

    private fun countryCode(context: Context): String {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        return listOfNotNull(tm?.simCountryIso, tm?.networkCountryIso, Locale.getDefault().country)
            .map { it.uppercase(Locale.ROOT) }
            .firstOrNull { it.length == 2 }
            ?: ""
    }

    // Centre and a zoom that fits the country on a phone screen.
    private val countries = mapOf(
        "HK" to Region(22.35, 114.15, 10.0),
        "MO" to Region(22.19, 113.55, 11.0),
        "SG" to Region(1.35, 103.82, 10.0),
        "TW" to Region(23.7, 121.0, 7.0),
        "CN" to Region(35.0, 105.0, 4.0),
        "JP" to Region(36.5, 138.0, 5.0),
        "KR" to Region(36.3, 127.8, 6.0),
        "TH" to Region(15.0, 101.0, 5.5),
        "VN" to Region(16.0, 107.5, 5.0),
        "MY" to Region(3.5, 108.0, 5.5),
        "ID" to Region(-2.5, 118.0, 4.0),
        "PH" to Region(12.5, 122.0, 5.0),
        "IN" to Region(22.0, 79.0, 4.5),
        "AE" to Region(24.3, 54.3, 7.0),
        "QA" to Region(25.3, 51.2, 8.0),
        "SA" to Region(24.0, 45.0, 5.0),
        "TR" to Region(39.0, 35.0, 5.5),
        "IL" to Region(31.5, 34.9, 7.0),
        "AU" to Region(-26.0, 134.0, 4.0),
        "NZ" to Region(-41.0, 173.0, 5.0),
        "GB" to Region(54.5, -3.0, 5.5),
        "IE" to Region(53.3, -8.0, 6.5),
        "FR" to Region(46.6, 2.5, 5.5),
        "DE" to Region(51.1, 10.4, 5.5),
        "NL" to Region(52.2, 5.4, 7.0),
        "BE" to Region(50.6, 4.6, 7.5),
        "CH" to Region(46.8, 8.2, 7.0),
        "AT" to Region(47.6, 14.2, 6.5),
        "IT" to Region(42.5, 12.5, 5.5),
        "ES" to Region(40.2, -3.7, 5.5),
        "PT" to Region(39.6, -8.0, 6.5),
        "SE" to Region(62.0, 16.0, 4.5),
        "NO" to Region(64.0, 12.0, 4.5),
        "DK" to Region(56.0, 10.0, 6.5),
        "FI" to Region(64.0, 26.0, 4.5),
        "PL" to Region(52.0, 19.5, 5.5),
        "CZ" to Region(49.8, 15.5, 6.5),
        "GR" to Region(38.5, 23.5, 6.0),
        "RU" to Region(60.0, 90.0, 3.0),
        "US" to Region(38.5, -97.0, 4.0),
        "CA" to Region(58.0, -96.0, 3.5),
        "MX" to Region(23.5, -102.0, 5.0),
        "BR" to Region(-12.0, -52.0, 4.0),
        "AR" to Region(-36.0, -65.0, 4.0),
        "CL" to Region(-35.0, -71.0, 4.0),
        "CO" to Region(4.5, -73.0, 5.5),
        "PE" to Region(-9.5, -75.0, 5.0),
        "ZA" to Region(-29.0, 25.0, 5.0),
        "EG" to Region(26.5, 30.0, 5.5),
        "KE" to Region(0.5, 37.8, 6.0),
        "NG" to Region(9.5, 8.0, 5.5),
        "MA" to Region(31.5, -7.0, 5.5)
    )
}
