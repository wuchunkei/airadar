package com.airadar.app.data

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.io.IOException
import kotlin.coroutines.resume

/**
 * Google Play subscriptions. The Play sheet does the paying; the purchase token
 * then goes to the server, which confirms it with Google and raises the tier.
 */
object Billing {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var client: BillingClient? = null
    private var onResult: ((Result<Membership>) -> Unit)? = null

    private fun client(context: Context): BillingClient =
        client ?: BillingClient.newBuilder(context.applicationContext)
            .setListener { result, purchases -> handlePurchases(result, purchases) }
            .enablePendingPurchases()
            .build()
            .also { client = it }

    private suspend fun connected(context: Context): BillingClient {
        val c = client(context)
        if (c.isReady) return c
        return suspendCancellableCoroutine { cont ->
            c.startConnection(object : BillingClientStateListener {
                override fun onBillingSetupFinished(result: BillingResult) {
                    if (result.responseCode == BillingClient.BillingResponseCode.OK) cont.resume(c)
                    else cont.resumeWith(Result.failure(IOException("Google Play billing unavailable: ${result.debugMessage}")))
                }

                override fun onBillingServiceDisconnected() {}
            })
        }
    }

    /** Opens Google Play's purchase sheet for [productId]; the result arrives through [onDone]. */
    suspend fun subscribe(activity: Activity, productId: String, onDone: (Result<Membership>) -> Unit) {
        val c = connected(activity)
        val query = QueryProductDetailsParams.newBuilder()
            .setProductList(
                listOf(
                    QueryProductDetailsParams.Product.newBuilder()
                        .setProductId(productId)
                        .setProductType(BillingClient.ProductType.SUBS)
                        .build()
                )
            )
            .build()
        val details: ProductDetails = suspendCancellableCoroutine { cont ->
            c.queryProductDetailsAsync(query) { result, list ->
                val d = list.firstOrNull()
                if (result.responseCode == BillingClient.BillingResponseCode.OK && d != null) cont.resume(d)
                else cont.resumeWith(Result.failure(IOException("Plan $productId is not available on Google Play yet.")))
            }
        }
        val offerToken = details.subscriptionOfferDetails?.firstOrNull()?.offerToken
            ?: throw IOException("Plan $productId has no offer configured.")
        val params = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(
                listOf(
                    BillingFlowParams.ProductDetailsParams.newBuilder()
                        .setProductDetails(details)
                        .setOfferToken(offerToken)
                        .build()
                )
            )
            .build()
        onResult = onDone
        val launched = c.launchBillingFlow(activity, params)
        if (launched.responseCode != BillingClient.BillingResponseCode.OK) {
            onResult = null
            throw IOException("Could not open Google Play: ${launched.debugMessage}")
        }
    }

    /** Re-sends any active subscription to the server — after a reinstall, say. */
    suspend fun restore(context: Context) {
        val c = connected(context)
        val params = QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()
        c.queryPurchasesAsync(params) { _, purchases -> handlePurchases(null, purchases) }
    }

    private fun handlePurchases(result: BillingResult?, purchases: List<Purchase>?) {
        if (result != null && result.responseCode != BillingClient.BillingResponseCode.OK) {
            val cancelled = result.responseCode == BillingClient.BillingResponseCode.USER_CANCELED
            onResult?.invoke(Result.failure(IOException(if (cancelled) "Purchase cancelled." else result.debugMessage)))
            onResult = null
            return
        }
        val active = purchases.orEmpty().filter { it.purchaseState == Purchase.PurchaseState.PURCHASED }
        if (active.isEmpty()) return
        scope.launch {
            var last: Result<Membership>? = null
            active.forEach { purchase ->
                val productId = purchase.products.firstOrNull() ?: return@forEach
                last = runCatching { BackendClient.confirmPurchase(productId, purchase.purchaseToken) }
                if (last?.isSuccess == true && !purchase.isAcknowledged) {
                    client?.acknowledgePurchase(
                        AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build()
                    ) { }
                }
            }
            last?.let { onResult?.invoke(it) }
            onResult = null
        }
    }
}
