// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
//
// Единая точка доступа к Backend и FreeTurnManager.
//
// MainActivity.onCreate() создаёт Backend и кладёт ссылку сюда,
// LaLuneVpnService.establishTun() забирает freeTurnManager для StartTunnel.

package com.lalune.lalune

import android.app.Application

class LaLuneApplication : Application() {

    @Volatile var backend: Backend? = null
        private set

    @Volatile var freeTurnManager: FreeTurnManager? = null
        private set

    fun setBackend(b: Backend, ft: FreeTurnManager?) {
        backend = b
        freeTurnManager = ft
    }
}
